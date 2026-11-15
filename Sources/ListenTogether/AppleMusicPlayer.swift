import AppKit
import WebKit

/// Plays Apple Music through the official web player (music.apple.com),
/// hosted in its own window and driven through the page's MusicKit instance.
/// Music.app can't be told to play a catalog song, but MusicKit can.
@MainActor
final class AppleMusicPlayer: NSObject, MusicPlayer, WKNavigationDelegate, WKUIDelegate {
    let service = MusicService.appleMusic
    static let home = URL(string: "https://music.apple.com/")!
    // music.apple.com only offers full playback to browsers it recognizes.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    private(set) var window: NSWindow?
    private var popups: [NSWindow] = []
    private var loaded = false
    private var bridgeId: String?
    /// Set when the page was (re)loaded, which resets MusicKit's volume.
    var needsVolumeRestore = false

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        if #available(macOS 14.0, *) {
            // Keep the player running at full speed while its window is hidden.
            config.preferences.inactiveSchedulingPolicy = .none
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        webView.customUserAgent = Self.userAgent
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// The web view lives in a window from the start (hidden until shown), so
    /// WebKit treats it as a real page and keeps playing.
    private func ensureWindow() {
        if window == nil {
            let w = NSWindow(contentRect: webView.frame,
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Apple Music — ListenTogether"
            w.isReleasedWhenClosed = false
            w.contentView = webView
            w.center()
            w.setFrameAutosaveName("AppleMusicWebPlayer")
            window = w
        }
    }

    func showWindow() {
        ensureWindow()
        if !loaded { load() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func load() {
        loaded = true
        webView.load(URLRequest(url: Self.home))
    }

    // MARK: MusicPlayer

    func connect() async throws {
        ensureWindow()
        if !loaded { load() }
        // Wait for the page's MusicKit to come up.
        for _ in 0..<60 {
            if let s = try? await snapshot(), s.ready { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw PlayerError("The Apple Music web player didn't load. Check your connection, then open the Apple Music window.")
    }

    /// Run `window.__lt[name](arg)` in the page, installing the bridge first.
    private func call(_ name: String, _ arg: Any? = nil) async throws -> Any? {
        let argJSON = arg.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])) ?? Data("null".utf8), as: UTF8.self) } ?? "null"
        let script = """
        if (!window.__lt || window.__lt.version !== \(EmbeddedJS.appleVersion)) { eval(source); }
        if (!window.__lt) throw new Error('bridge not installed');
        return JSON.stringify(await window.__lt[name](JSON.parse(argJSON)));
        """
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: ["source": EmbeddedJS.apple, "name": name, "argJSON": argJSON],
            in: nil, contentWorld: .page)
        guard let text = result as? String, let data = text.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func track(from d: [String: Any]?) -> TrackInfo? {
        guard let d, let id = d["id"] as? String, let title = d["title"] as? String else { return nil }
        return TrackInfo(
            service: .appleMusic, id: id, albumId: nil, title: title,
            artist: d["artist"] as? String ?? "", album: d["album"] as? String ?? "",
            isrc: d["isrc"] as? String, durationMs: (d["durationMs"] as? NSNumber)?.intValue ?? 0)
    }

    func snapshot() async throws -> PlayerSnapshot {
        guard let d = try await call("state") as? [String: Any] else { throw PlayerError("Apple Music sent no state") }
        if let id = d["bridge"] as? String, id != bridgeId, d["ready"] as? Bool == true {
            bridgeId = id
            needsVolumeRestore = true
        }
        return PlayerSnapshot(
            ready: d["ready"] as? Bool ?? false,
            authorized: d["authorized"] as? Bool ?? false,
            track: track(from: d["track"] as? [String: Any]),
            playing: d["playing"] as? Bool ?? false,
            positionMs: (d["positionMs"] as? NSNumber)?.intValue ?? 0,
            loading: d["loading"] as? Bool ?? false,
            volume: (d["volume"] as? NSNumber)?.doubleValue,
            queueVersion: (d["queueVersion"] as? NSNumber)?.intValue)
    }

    func setVolume(_ volume: Double) async throws { _ = try await call("setVolume", volume) }

    func play() async throws { _ = try await call("play") }
    func pause() async throws { _ = try await call("pause") }

    func queueState() async throws -> AppQueue {
        guard let d = try await call("queueState") as? [String: Any] else { return AppQueue() }
        return AppQueue(keys: d["keys"] as? [String] ?? [], upcoming: d["upcoming"] as? [String] ?? [],
                        current: d["current"] as? String)
    }

    func addToQueue(_ tracks: [TrackInfo], next: Bool) async throws -> [String: String] {
        guard !tracks.isEmpty,
              let d = try await call("addToQueue", ["ids": tracks.map(\.id), "next": next]) as? [String: Any] else { return [:] }
        if let error = d["error"] as? String { throw PlayerError(error) }
        var out: [String: String] = [:]
        for a in d["added"] as? [[String: Any]] ?? [] {
            if let id = a["id"] as? String, let key = a["key"] as? String, out[id] == nil { out[id] = key }
        }
        return out
    }

    func removeFromQueue(_ keys: [String]) async throws -> Bool {
        let d = try await call("removeFromQueue", keys) as? [String: Any]
        return d?["ok"] as? Bool ?? false
    }

    func playQueued(_ key: String, in queue: AppQueue) async throws -> Bool {
        let d = try await call("playQueued", key) as? [String: Any]
        return d?["ok"] as? Bool ?? false
    }

    func skipToNext() async throws { _ = try await call("next") }

    func queueTracks(_ keys: [String]) async throws -> [String: TrackInfo?] {
        guard !keys.isEmpty, let dict = try await call("queueTracks", keys) as? [String: Any] else { return [:] }
        if addedAs.count > 500 { addedAs.removeAll() }
        var out: [String: TrackInfo?] = [:]
        for (key, value) in dict {
            let d = value as? [String: Any]
            out[key] = track(from: d)
            if let playNext = d?["playNext"] as? Bool { addedAs[key] = playNext }
        }
        return out
    }
    private var addedAs: [String: Bool] = [:]
    func addedAsPlayNext(_ key: String) -> Bool? { addedAs[key] }
    func seek(toMs ms: Int) async throws { _ = try await call("seek", ms) }

    /// Test hook (LT_TEST_DIR): run JavaScript in the page.
    func evaluateForTest(_ js: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    }

    func authorize() async throws {
        showWindow()
        _ = try await call("authorize")
    }

    func candidates(for t: TrackInfo) async throws -> [TrackInfo] {
        var out: [TrackInfo] = []
        if let isrc = t.isrc, !isrc.isEmpty,
           let list = try await call("search", ["isrc": isrc]) as? [[String: Any]] {
            out += list.compactMap { track(from: $0) }
        }
        if Matcher.best(for: t, in: out) == nil,
           let list = try await call("search", ["query": Matcher.searchQuery(for: t), "limit": 15]) as? [[String: Any]] {
            out += list.compactMap { track(from: $0) }
        }
        return out
    }

    func load(_ t: TrackInfo, positionMs: Int, play: Bool) async throws {
        let started = Date()
        _ = try await call("playSong", ["id": t.id, "positionMs": positionMs, "play": play])
        // Loading took a moment; catch up with the shared position.
        if play {
            let lag = Int(Date().timeIntervalSince(started) * 1000)
            if lag > 400 { try await seek(toMs: positionMs + lag) }
        }
    }

    // MARK: Web view

    // The Apple ID sign-in opens a popup that talks back to the opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.customUserAgent = Self.userAgent
        popup.uiDelegate = self
        let w = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in to Apple Music"
        w.isReleasedWhenClosed = false
        w.contentView = popup
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let i = popups.firstIndex(where: { $0.contentView === webView }) {
            popups[i].close()
            popups.remove(at: i)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { loaded = true }
    }
}
