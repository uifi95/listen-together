import AppKit
import Foundation

/// Controls the Qobuz desktop app. Qobuz has no scripting interface, so this
/// opens the Node inspector of its Electron main process (SIGUSR1, as Node
/// does for any process), installs a small bridge there and drives the
/// player through Qobuz's own Redux actions and media-key IPC.
@MainActor
final class QobuzPlayer: MusicPlayer {
    let service = MusicService.qobuz
    static let bundleId = "com.qobuz.desktop"

    private var cdp: CDPClient?
    private var pid: pid_t = 0

    func connect() async throws {
        if let cdp, !cdp.isClosed, isRunning(pid) { return }
        cdp?.close()
        cdp = nil

        let app = try await runningQobuz()
        pid = app.processIdentifier

        var wsURL = await findInspector(pid: pid)
        if wsURL == nil {
            kill(pid, SIGUSR1)
            for _ in 0..<20 where wsURL == nil {
                try await Task.sleep(nanoseconds: 250_000_000)
                wsURL = await findInspector(pid: pid)
            }
        }
        guard let wsURL else { throw PlayerError("Qobuz did not open its inspector. Try quitting and reopening Qobuz.") }

        let client = CDPClient(url: wsURL)
        client.start()
        let install = "(\(EmbeddedJS.qobuzHost.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))))(\(jsonString(EmbeddedJS.qobuzPage)))"
        let result = try await client.evaluate(install, timeout: 40)
        guard (result as? String) == "ok" else { throw PlayerError("Qobuz bridge: \(result ?? "no result")") }
        cdp = client
    }

    private func isRunning(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    private func runningQobuz() async throws -> NSRunningApplication {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) else {
            throw PlayerError("Qobuz is not installed")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first,
               app.isFinishedLaunching {
                // Give the window time to load before the bridge goes in.
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return app
            }
        }
        throw PlayerError("Qobuz did not start")
    }

    /// The inspector's WebSocket URL, if the main process has one open.
    private func findInspector(pid: pid_t) async -> URL? {
        // Node's inspector usually takes 9229; Chromium's own port (if Qobuz
        // was started with one) lists pages, which are skipped below.
        let ports = listeningPorts(pid: pid).sorted { a, _ in a == 9229 }
        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 1
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            // Node targets have no "page"/"iframe" type, unlike Chromium's.
            for target in list where (target["type"] as? String ?? "node") == "node" {
                if let s = target["webSocketDebuggerUrl"] as? String, let u = URL(string: s) { return u }
            }
        }
        return nil
    }

    private func listeningPorts(pid: pid_t) -> [Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-nP", "-Fn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.hasPrefix("n") }
            .compactMap { line in line.split(separator: ":").last.flatMap { Int($0) } }
    }

    private func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }

    /// Call the bridge; reconnects once if Qobuz was restarted.
    private func call(_ name: String, _ arg: Any? = nil) async throws -> Any? {
        for attempt in 0..<2 {
            try await connect()
            guard let cdp else { throw PlayerError("Not connected to Qobuz") }
            let argJSON: String
            if let arg {
                argJSON = String(decoding: try JSONSerialization.data(withJSONObject: arg, options: [.fragmentsAllowed]), as: UTF8.self)
            } else {
                argJSON = "null"
            }
            do {
                let raw = try await cdp.evaluate("global.__listenTogether.call(\(jsonString(name)), \(argJSON))")
                guard let text = raw as? String, let data = text.data(using: .utf8) else { return nil }
                let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                if let dict = value as? [String: Any], let error = dict["error"] as? String {
                    throw PlayerError("Qobuz: \(error)")
                }
                return value
            } catch let error as PlayerError where error.message.contains("__listenTogether") && attempt == 0 {
                // The bridge is gone (Qobuz reloaded); install it again.
                self.cdp?.close()
                self.cdp = nil
            }
        }
        throw PlayerError("Qobuz bridge unavailable")
    }

    private func track(from d: [String: Any]?) -> TrackInfo? {
        guard let d, let id = d["id"] as? String, let title = d["title"] as? String else { return nil }
        return TrackInfo(
            service: .qobuz, id: id, albumId: d["albumId"] as? String, title: title,
            artist: d["artist"] as? String ?? "", album: d["album"] as? String ?? "",
            isrc: d["isrc"] as? String, durationMs: (d["durationMs"] as? NSNumber)?.intValue ?? 0)
    }

    func snapshot() async throws -> PlayerSnapshot {
        guard let d = try await call("state") as? [String: Any] else { throw PlayerError("Qobuz sent no state") }
        return PlayerSnapshot(
            track: track(from: d["track"] as? [String: Any]),
            playing: d["playing"] as? Bool ?? false,
            positionMs: (d["positionMs"] as? NSNumber)?.intValue ?? 0,
            loading: d["loading"] as? Bool ?? false,
            queueVersion: (d["queueVersion"] as? NSNumber)?.intValue)
    }

    func play() async throws { _ = try await call("play") }
    func pause() async throws { _ = try await call("pause") }

    func queueState() async throws -> AppQueue {
        guard let d = try await call("queueState") as? [String: Any] else { return AppQueue() }
        return AppQueue(keys: d["keys"] as? [String] ?? [], upcoming: d["upcoming"] as? [String] ?? [],
                        current: d["current"] as? String)
    }

    /// Qobuz queues them a moment later (it fetches the list first), so no
    /// keys come back; the engine recognizes the new items by track id.
    func addToQueue(_ tracks: [TrackInfo], next: Bool) async throws -> [String: String] {
        let usable = tracks.filter { $0.albumId != nil }
        guard !usable.isEmpty else { throw PlayerError("Qobuz track without an album") }
        let list = usable.map { ["id": $0.id, "albumId": $0.albumId ?? ""] }
        _ = try await call("addToQueue", ["tracks": list, "next": next])
        return [:]
    }

    /// Qobuz's remove action isn't reachable from outside.
    func removeFromQueue(_ keys: [String]) async throws -> Bool { false }

    /// Only the next item: Qobuz's "next" media key gets there.
    func playQueued(_ key: String, in queue: AppQueue) async throws -> Bool {
        guard queue.upcoming.first == key else { return false }
        try await skipToNext()
        return true
    }

    func skipToNext() async throws { _ = try await call("next") }

    /// Whether playing a single track (instead of its whole album) works
    /// with this Qobuz version; nil until tried.
    private var playOnlyWorks: Bool?

    func queueTracks(_ keys: [String]) async throws -> [String: TrackInfo?] {
        guard !keys.isEmpty, let dict = try await call("queueTracks", keys) as? [String: Any] else { return [:] }
        var out: [String: TrackInfo?] = [:]
        for (key, value) in dict { out[key] = track(from: value as? [String: Any]) }
        return out
    }
    func seek(toMs ms: Int) async throws { _ = try await call("seek", ms) }

    func candidates(for t: TrackInfo) async throws -> [TrackInfo] {
        var out: [TrackInfo] = []
        if let isrc = t.isrc, !isrc.isEmpty,
           let list = try await call("search", ["query": isrc, "limit": 10]) as? [[String: Any]] {
            out += list.compactMap { track(from: $0) }
        }
        if Matcher.best(for: t, in: out) == nil,
           let list = try await call("search", ["query": Matcher.searchQuery(for: t), "limit": 15]) as? [[String: Any]] {
            out += list.compactMap { track(from: $0) }
        }
        return out
    }

    func load(_ t: TrackInfo, positionMs: Int, play shouldPlay: Bool) async throws {
        guard let albumId = t.albumId else {
            // Only an id: look it up to learn its album.
            let found = try await candidates(for: t).first { $0.id == t.id }
            guard let found, found.albumId != nil else { throw PlayerError("Can't find that Qobuz track's album") }
            return try await load(found, positionMs: positionMs, play: shouldPlay)
        }
        let started = Date()
        // Just the track, so the room's queue (copied in after it) is what
        // plays next, not the rest of its album. Falls back to the album.
        var switched = false
        if playOnlyWorks != false {
            _ = try await call("playOnly", ["trackId": t.id, "albumId": albumId])
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 150_000_000)
                if try await snapshot().track?.id == t.id { switched = true; break }
            }
            if playOnlyWorks == nil {
                playOnlyWorks = switched
                LogFile.write("qobuz: single-track play \(switched ? "works" : "doesn't work, using albums")")
            }
        }
        if !switched { _ = try await call("playTrack", ["trackId": t.id, "albumId": albumId]) }
        // Wait for Qobuz to switch to the track and start streaming it.
        var snap = try await snapshot()
        while !(snap.track?.id == t.id && !snap.loading && snap.playing) && Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(nanoseconds: 150_000_000)
            snap = try await snapshot()
        }
        // The caller's position was for when it asked; account for the wait.
        let target = positionMs + Int(Date().timeIntervalSince(started) * 1000 * (shouldPlay ? 1 : 0))
        if target > 1500 { try await seek(toMs: target) }
        if !shouldPlay { try await pause() }
    }
}
