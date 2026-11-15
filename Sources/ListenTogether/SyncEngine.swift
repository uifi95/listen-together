import AppKit
import Foundation

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

/// Keeps the local player on the room's shared timeline.
///
/// Every half second it reads the local player. A change the user made here
/// (new track, play/pause, a seek) becomes the new shared state and goes to
/// the relay. A shared state from the other person is applied locally: the
/// track is found on this service, then play/pause and position follow.
/// Small drift is corrected by seeking.
@MainActor
final class SyncEngine: ObservableObject {
    // Settings
    @Published var service: MusicService {
        didSet {
            guard service != oldValue else { return }
            Self.defaults.set(service.rawValue, forKey: "service")
            playerConnected = false
            baseline = nil
            appQueueVersion = nil
            appQueueKeys = []
            pendingAdds = []
            local = PlayerSnapshot(ready: false)
            playerStatus = "Connecting to \(service.displayName)…"
        }
    }
    @Published var relayURL: String { didSet { Self.defaults.set(relayURL, forKey: "relayURL") } }
    @Published var room: String { didSet { Self.defaults.set(room, forKey: "room") } }
    @Published var name: String { didSet { Self.defaults.set(name, forKey: "name") } }
    /// Apple Music volume as a slider position, 0...1. The player's gain is
    /// its cube (see `gain(forPosition:)`), so the slider follows loudness.
    @Published private(set) var appleVolume: Double
    private var lastVolumeSet = Date.distantPast
    /// Settings. LT_PROFILE=<name> keeps a separate set, so a second copy
    /// (or a test) on the same Mac doesn't share or overwrite them.
    nonisolated static let defaults: UserDefaults = {
        if let profile = ProcessInfo.processInfo.environment["LT_PROFILE"],
           let d = UserDefaults(suiteName: "app.listentogether.mac.\(profile)") { return d }
        return .standard
    }()

    /// LT_TEST_DIR=<dir>: test hook. Each tick, a file <dir>/cmd is run and
    /// deleted ("apple-js <code>" evaluates in the Apple Music page; "skip").
    /// Only active when the app is launched with that variable.
    nonisolated static let testDir = ProcessInfo.processInfo.environment["LT_TEST_DIR"]

    /// LT_DEBUG=1 prints player state changes to stdout.
    static let debug = ProcessInfo.processInfo.environment["LT_DEBUG"] != nil
    private var lastDebugLine = ""

    // State shown in the UI
    @Published private(set) var relayStatus: RelayClient.Status = .disconnected
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var myId: String?
    @Published private(set) var playerStatus = "Starting…"
    @Published private(set) var playerConnected = false
    @Published private(set) var local = PlayerSnapshot(ready: false)
    @Published private(set) var shared: SharedState?
    @Published private(set) var log: [LogLine] = []

    let relay = RelayClient()
    let apple = AppleMusicPlayer()
    let qobuz = QobuzPlayer()
    var player: MusicPlayer { service == .qobuz ? qobuz : apple }

    var partners: [Peer] { peers.filter { $0.id != myId } }
    var needsAppleSignIn: Bool { service == .appleMusic && local.ready && !local.authorized }

    // Shared queue
    @Published private(set) var queue = SharedQueue()
    private var appQueueVersion: Int?
    private var appQueueKeys: [String] = []
    private struct PendingAdd { var key: String; var playNext: Bool; var addedAt: Double; var seq: Int; var since: Date }
    private var pendingAdds: [PendingAdd] = []

    private var baseline: PlayerSnapshot?
    private var baselineTime = Date()
    private var suppressUntil = Date.distantPast
    private var lastCorrection = Date.distantPast
    private var pendingRemote: SharedState?
    private var applying = false
    private var ticking = false
    private var loop: Task<Void, Never>?

    // Thresholds (milliseconds)
    private let seekJump = 2500       // a jump this big that we didn't cause is a user seek
    private let driftLimit = 1200     // further apart than this gets corrected
    private let applyTolerance = 800  // when applying a remote state

    init() {
        let d = Self.defaults
        service = MusicService(rawValue: d.string(forKey: "service") ?? "") ?? .qobuz
        relayURL = d.string(forKey: "relayURL") ?? "ws://localhost:47900"
        room = d.string(forKey: "room") ?? SyncEngine.randomRoom()
        name = d.string(forKey: "name") ?? (Host.current().localizedName ?? "Me")
        appleVolume = d.object(forKey: "appleVolumePosition") as? Double ?? 0.8

        relay.onStatus = { [weak self] status in
            guard let self else { return }
            self.relayStatus = status
            switch status {
            case .connected: self.note("Connected to room \(self.room)")
            case .failed(let why):
                // Quick-tunnel rooms vanish when the host closes them.
                if self.relayURL.contains("trycloudflare.com") && !self.isHosting {
                    self.note("Can't reach the room. If the host closed it, click Leave Room. (\(why))")
                } else {
                    self.note("Relay: \(why)")
                }
            default: break
            }
        }
        relay.onPeers = { [weak self] peers, myId, joined in self?.peersChanged(peers, myId: myId, joined: joined) }
        relay.onState = { [weak self] state in self?.receive(state) }
        // Back into the room the app was in when it last quit.
        if d.bool(forKey: "inRoom") { DispatchQueue.main.async { self.connectRelay() } }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// A hosted room's code is also its password, so it gets extra randomness.
    nonisolated static func hostedRoomCode() -> String {
        "\(randomRoom())-\(String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(5)))"
    }

    nonisolated static func randomRoom() -> String {
        let words = ["amber", "breeze", "cobalt", "dune", "ember", "fjord", "grove", "harbor", "indigo", "juniper",
                     "kelp", "lumen", "meadow", "nova", "opal", "pine", "quartz", "river", "sable", "tide"]
        return "\(words.randomElement()!)-\(words.randomElement()!)-\(Int.random(in: 10...99))"
    }

    // MARK: Relay

    var isRelayActive: Bool { relayStatus != .disconnected }

    func connectRelay() {
        guard let url = RelayClient.makeURL(base: relayURL, room: room, name: name) else {
            note("That relay address doesn't look right")
            return
        }
        shared = nil
        queue = SharedQueue()
        Self.defaults.set(true, forKey: "inRoom")
        relay.connect(to: url)
    }

    func disconnectRelay() {
        Self.defaults.set(false, forKey: "inRoom")
        stopHosting()
        relay.disconnect()
        peers = []
        myId = nil
        shared = nil
    }

    // MARK: Hosting a room on this Mac

    enum HostState: Equatable {
        case idle
        case starting(String)
        case running(invite: URL)
        case failed(String)
    }

    @Published private(set) var host: HostState = .idle
    private var hostServer: HostServer?
    private var tunnel: CloudflareTunnel?

    var isHosting: Bool {
        switch host {
        case .starting, .running: return true
        default: return false
        }
    }

    var cloudflaredInstalled: Bool { CloudflareTunnel.findBinary() != nil }

    /// Runs the relay on this Mac, opens a Cloudflare tunnel to it and joins.
    func createRoom() {
        guard !isHosting else { return }
        if isRelayActive { disconnectRelay() }
        let code = Self.hostedRoomCode()
        let server = HostServer(room: code, hostName: name)
        let tunnel = CloudflareTunnel()
        host = .starting("Starting room…")
        Task {
            do {
                let port = try await server.start()
                host = .starting("Opening Cloudflare tunnel…")
                let publicURL = try await tunnel.start(localPort: port)
                host = .starting("Waiting for the link to go live…")
                _ = await CloudflareTunnel.waitUntilPublic(publicURL)
                guard case .starting = host else {  // cancelled meanwhile
                    server.stop(); tunnel.stop(); return
                }
                server.publicURL = publicURL
                hostServer = server
                self.tunnel = tunnel
                room = code
                relayURL = publicURL.absoluteString
                // This Mac talks to its own relay directly, not through Cloudflare.
                if let local = RelayClient.makeURL(base: "ws://127.0.0.1:\(port)", room: code, name: name) {
                    shared = nil
                    queue = SharedQueue()
                    relay.connect(to: local)
                }
                // A tunnel address dies with the app; don't rejoin it on launch.
                Self.defaults.set(false, forKey: "inRoom")
                if let invite = server.inviteLink { host = .running(invite: invite) }
                note("Room created. Send your friend the invite link.")
            } catch {
                server.stop()
                tunnel.stop()
                host = .failed(error.localizedDescription)
            }
        }
    }

    func stopHosting() {
        tunnel?.stop()
        hostServer?.stop()
        tunnel = nil
        hostServer = nil
        if host != .idle { host = .idle }
    }

    /// Join from an invite: the https://…/join/<room> link or listentogether://join?….
    @discardableResult
    func join(link: String) -> Bool {
        guard let invite = InviteLink.parse(link) else {
            note("That doesn't look like a ListenTogether invite link")
            return false
        }
        if isRelayActive || isHosting { disconnectRelay() }
        relayURL = invite.relay
        room = invite.room
        connectRelay()
        return true
    }

    private func peersChanged(_ newPeers: [Peer], myId: String?, joined: Bool) {
        let before = Set(partners.map(\.id))
        self.myId = myId
        peers = newPeers
        let after = partners
        if joined {
            if !after.isEmpty { note("With \(after.map(\.name).joined(separator: ", "))") }
            return
        }
        for p in after where !before.contains(p.id) { note("\(p.name) joined") }
        for id in before where !after.contains(where: { $0.id == id }) { note("Someone left") }
        // Someone new arrived: bring them to what's playing here. (The
        // newcomer doesn't do this, so the person already in the room leads.)
        if after.contains(where: { !before.contains($0.id) }), local.track != nil, !applying {
            publish(local, quiet: true)
        }
    }

    private func receive(_ state: SharedState) {
        // Queue changes always count, even from a state that is otherwise older.
        let fresh = queue.merge(items: state.queue ?? [], removed: state.removed ?? [])
        for item in fresh {
            note("\(item.addedBy) queued \(item.track.summary)\(item.playNext ? " to play next" : "")")
        }
        if Self.debug && (!fresh.isEmpty || !(state.removed ?? []).isEmpty) {
            print("queue: \(queue.items.map { $0.track.title }.joined(separator: " | "))"); fflush(stdout)
        }
        if let mine = shared, mine.at > state.at, mine.from == myId {
            // Ours is newer; the other side will follow ours.
            return
        }
        pendingRemote = state
        // Never while a local check is mid-way; tick() picks it up after.
        if !applying && !ticking { Task { await drainRemote() } }
    }

    private func drainRemote() async {
        guard !applying else { return }
        applying = true
        while let s = pendingRemote {
            pendingRemote = nil
            shared = s
            do {
                try await apply(s)
            } catch {
                note("Couldn't follow: \(error.localizedDescription)")
            }
        }
        applying = false
        baseline = nil
        suppressUntil = Date().addingTimeInterval(1.5)
    }

    private func apply(_ s: SharedState, announce: Bool = true) async throws {
        let who = s.fromName ?? "Partner"
        guard let target = s.track else {
            note("\(who) stopped")
            if local.playing { try await player.pause() }
            return
        }
        let snap = try await player.snapshot()
        if Matcher.isSame(snap.track, target) {
            if s.playing != snap.playing {
                note("\(who) \(s.playing ? "pressed play" : "paused")")
                if s.playing { try await player.play() } else { try await player.pause() }
            }
            let expected = s.expectedPosition(atRelayTime: relay.relayNow)
            if abs(snap.positionMs - expected) > applyTolerance {
                if abs(snap.positionMs - expected) > seekJump { note("\(who) jumped to \(Self.time(expected))") }
                try await player.seek(toMs: expected)
            }
            return
        }

        if announce { note("\(who) is playing \(target.summary)") }
        var match: TrackInfo?
        if target.service == service {
            match = target
        } else {
            playerStatus = "Finding it on \(service.displayName)…"
            match = Matcher.best(for: target, in: try await player.candidates(for: target))
        }
        guard let match else {
            note("Couldn't find \(target.summary) on \(service.displayName)")
            if snap.playing { try await player.pause() }
            return
        }
        try await player.load(match, positionMs: s.expectedPosition(atRelayTime: relay.relayNow), play: s.playing)
        playerStatus = "Connected to \(service.displayName)"
    }

    // MARK: Local player

    private func runTestCommand(in dir: String) async {
        let path = (dir as NSString).appendingPathComponent("cmd")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.debug { print("test: \(line.prefix(60))"); fflush(stdout) }
        if line.hasPrefix("apple-js ") {
            do { try await apple.evaluateForTest(String(line.dropFirst(9))) } catch { print("test error: \(error)") }
        } else if line == "skip" {
            await playFromQueue(nil)
        } else if line == "create-room" {
            createRoom()
        }
    }

    private func tick() async {
        guard !applying else { return }
        if let dir = Self.testDir { await runTestCommand(in: dir) }
        ticking = true
        defer {
            ticking = false
            if pendingRemote != nil && !applying { Task { await drainRemote() } }
        }
        let p = player
        do {
            if !playerConnected {
                playerStatus = "Connecting to \(service.displayName)…"
                try await p.connect()
                guard p === player else { return }
                playerConnected = true
                playerStatus = "Connected to \(service.displayName)"
            }
            let snap = try await p.snapshot()
            guard p === player, !applying else { return }
            local = snap
            if service == .appleMusic, snap.ready { await syncAppleVolume(snap) }
            if Self.debug {
                let line = "player \(service.rawValue) ready=\(snap.ready) track=\(snap.track?.title ?? "-") playing=\(snap.playing) volume=\(snap.volume.map { String(format: "%.2f", $0) } ?? "-") slider=\(String(format: "%.2f", appleVolume))"
                if line != lastDebugLine { lastDebugLine = line; print(line); fflush(stdout) }
            }
            await watchAppQueue(snap)
            guard !applying else { return }
            await detectChanges(snap)
        } catch {
            guard p === player else { return }
            playerConnected = false
            local = PlayerSnapshot(ready: false)
            playerStatus = error.localizedDescription
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func detectChanges(_ snap: PlayerSnapshot) async {
        let now = Date()
        let base = baseline
        let dt = Int(now.timeIntervalSince(baselineTime) * 1000)
        baseline = snap
        baselineTime = now
        guard let base, now >= suppressUntil, !snap.loading, !base.loading else { return }

        // The shared song just finished here (the app moved on by itself or
        // stopped at the end): the shared queue decides what's next.
        let duration = base.track?.durationMs ?? 0
        let baseEnded = base.playing && duration > 0 && base.positionMs >= duration - 3000
        let baseWasShared = shared?.track == nil || Matcher.isSame(base.track, shared?.track)

        var changed = false
        if snap.track?.id != base.track?.id {
            if baseEnded && baseWasShared && !queue.isEmpty {
                await playFromQueue(nil)
                return
            }
            // A new track that isn't the shared one: the user (or the end of
            // the previous track) picked it here.
            if let t = snap.track, !Matcher.isSame(t, shared?.track) { changed = true }
        } else if snap.playing != base.playing {
            let ended = !snap.playing && duration > 0 && base.positionMs > duration - 2500
            if ended && baseWasShared && !queue.isEmpty {
                await playFromQueue(nil)
                return
            }
            if !ended && snap.playing != shared?.playing { changed = true }
        } else if snap.track != nil {
            let expected = base.positionMs + (base.playing ? dt : 0)
            if abs(snap.positionMs - expected) > seekJump { changed = true }
        }

        if changed {
            publish(snap)
        } else if queueOverdue() {
            // The shared song should have ended a while ago and nobody moved
            // on (an app that neither advanced nor stopped): move on.
            await playFromQueue(nil)
        } else {
            await correctDrift(snap)
        }
    }

    private func queueOverdue() -> Bool {
        guard !queue.isEmpty, let s = shared, s.playing, let d = s.track?.durationMs, d > 0 else { return false }
        return relay.relayNow - s.at - Double(d - s.positionMs) > 4000
    }

    /// Make `snap` the room's shared state.
    private func publish(_ snap: PlayerSnapshot, quiet: Bool = false) {
        let s = SharedState(track: snap.track, playing: snap.playing, positionMs: snap.positionMs,
                            at: relay.relayNow, from: myId, fromName: name,
                            queue: queue.items, removed: queue.removed)
        let previous = shared
        shared = s
        guard relayStatus == .connected else { return }
        relay.send(s)
        if quiet { return }
        if !Matcher.isSame(previous?.track, s.track), let t = s.track { note("You picked \(t.summary)") }
        else if previous?.playing != s.playing { note(s.playing ? "You pressed play" : "You paused") }
        else { note("You jumped to \(Self.time(s.positionMs))") }
    }

    private func correctDrift(_ snap: PlayerSnapshot) async {
        guard let s = shared, !partners.isEmpty, Matcher.isSame(snap.track, s.track),
              Date().timeIntervalSince(lastCorrection) > 4 else { return }
        do {
            if s.playing != snap.playing {
                lastCorrection = Date()
                if s.playing { try await player.play() } else { try await player.pause() }
            } else if s.playing {
                let expected = s.expectedPosition(atRelayTime: relay.relayNow)
                if abs(snap.positionMs - expected) > driftLimit {
                    lastCorrection = Date()
                    try await player.seek(toMs: expected)
                }
            } else {
                return
            }
            baseline = nil
            suppressUntil = Date().addingTimeInterval(1)
        } catch {
            note("Couldn't resync: \(error.localizedDescription)")
        }
    }

    // MARK: Shared queue

    /// Notices songs added to the app's own queue ("Add to Queue" or "Play
    /// Next") and puts them in the shared queue.
    private func watchAppQueue(_ snap: PlayerSnapshot) async {
        guard let version = snap.queueVersion else { return }
        do {
            if version != appQueueVersion {
                let keys = try await player.queueKeys()
                let firstLook = appQueueVersion == nil
                appQueueVersion = version
                let previous = appQueueKeys
                appQueueKeys = keys
                if !firstLook {
                    let now = relay.relayNow
                    for add in QueueDiff.additions(previous: previous, current: keys) {
                        for (i, key) in add.keys.enumerated() {
                            pendingAdds.append(PendingAdd(key: key, playNext: add.playNext, addedAt: now, seq: i, since: Date()))
                        }
                    }
                }
            }
            guard !pendingAdds.isEmpty else { return }
            let tracks = try await player.queueTracks(pendingAdds.map(\.key))
            var added: [QueueItem] = []
            pendingAdds.removeAll { p in
                guard let entry = tracks[p.key] else { return true }        // no longer in the app's queue
                guard let track = entry else { return Date().timeIntervalSince(p.since) > 15 }  // still loading
                added.append(QueueItem(id: UUID().uuidString, track: track, addedBy: name,
                                       addedAt: p.addedAt, seq: p.seq,
                                       playNext: player.addedAsPlayNext(p.key) ?? p.playNext))
                return true
            }
            guard !added.isEmpty else { return }
            queue.add(added)
            let what = added.count == 1 ? added[0].track.summary : "\(added.count) songs"
            note("You queued \(what)\(added[0].playNext ? " to play next" : "")")
            if Self.debug { print("queue: \(queue.items.map { $0.track.title }.joined(separator: " | "))"); fflush(stdout) }
            publishQueue()
        } catch {
            // The next tick tries again.
        }
    }

    /// Send the queue without changing what's playing.
    private func publishQueue() {
        let now = relay.relayNow
        var s: SharedState
        if let current = shared {
            s = current
            s.positionMs = current.expectedPosition(atRelayTime: now)
            s.at = now
        } else {
            s = SharedState(track: local.track, playing: local.playing, positionMs: local.positionMs, at: now)
        }
        s.from = myId
        s.fromName = name
        s.queue = queue.items
        s.removed = queue.removed
        shared = s
        if relayStatus == .connected { relay.send(s) }
    }

    /// Play `item`, or the next song in the queue, for everyone.
    private func playFromQueue(_ item: QueueItem?) async {
        guard let next = item ?? queue.first else { return }
        queue.remove(next.id)
        let s = SharedState(track: next.track, playing: true, positionMs: 0, at: relay.relayNow,
                            from: myId, fromName: name, queue: queue.items, removed: queue.removed)
        shared = s
        if relayStatus == .connected { relay.send(s) }
        note("Playing from the queue: \(next.track.summary) (queued by \(next.addedBy))")
        // The app may already have moved on to this very song by itself.
        if item == nil && Matcher.isSame(local.track, next.track) && local.playing { return }
        applying = true
        do { try await apply(s, announce: false) } catch { note("Couldn't play it: \(error.localizedDescription)") }
        applying = false
        baseline = nil
        suppressUntil = Date().addingTimeInterval(1.5)
    }

    /// Runs a queue action from the window once the current check is done.
    private func whenIdle(_ action: @escaping () async -> Void) {
        Task {
            while ticking || applying { try? await Task.sleep(nanoseconds: 50_000_000) }
            await action()
        }
    }

    func skipToNext() { whenIdle { await self.playFromQueue(nil) } }

    func playNow(_ item: QueueItem) { whenIdle { await self.playFromQueue(item) } }

    func removeFromQueue(_ item: QueueItem) {
        queue.remove(item.id)
        publishQueue()
    }

    func clearQueue() {
        queue.clear()
        publishQueue()
    }

    // MARK: Controls in this window

    func togglePlay() {
        Task {
            do {
                if local.playing { try await player.pause() } else { try await player.play() }
                try await Task.sleep(nanoseconds: 300_000_000)
                await publishNow()
            } catch { note(error.localizedDescription) }
        }
    }

    func seek(toMs ms: Int) {
        Task {
            do {
                try await player.seek(toMs: ms)
                try await Task.sleep(nanoseconds: 300_000_000)
                await publishNow()
            } catch { note(error.localizedDescription) }
        }
    }

    private func publishNow() async {
        guard let snap = try? await player.snapshot() else { return }
        local = snap
        baseline = snap
        baselineTime = Date()
        publish(snap)
    }

    // MARK: Volume (Apple Music)

    /// Loudness is heard logarithmically: a linear gain of 0.5 is only −6 dB
    /// and barely registers, so a linear slider seems to do nothing until
    /// near zero. A cubic taper (as many players use) spreads the change
    /// across the slider: 50% ≈ −18 dB, 25% ≈ −36 dB.
    nonisolated static func gain(forPosition p: Double) -> Double { pow(min(1, max(0, p)), 3) }
    nonisolated static func position(forGain g: Double) -> Double { cbrt(min(1, max(0, g))) }

    func setAppleVolume(_ position: Double) {
        let position = min(1, max(0, position))
        appleVolume = position
        lastVolumeSet = Date()
        Self.defaults.set(position, forKey: "appleVolumePosition")
        Task { try? await apple.setVolume(Self.gain(forPosition: position)) }
    }

    func nudgeAppleVolume(by delta: Double) { setAppleVolume(appleVolume + delta) }

    private func syncAppleVolume(_ snap: PlayerSnapshot) async {
        if apple.needsVolumeRestore {
            // A fresh page starts at MusicKit's 50%; put back the saved level.
            apple.needsVolumeRestore = false
            try? await apple.setVolume(Self.gain(forPosition: appleVolume))
        } else if let v = snap.volume, abs(v - Self.gain(forPosition: appleVolume)) > 0.005,
                  Date().timeIntervalSince(lastVolumeSet) > 1.5 {
            // Changed in the Apple Music window itself: keep that.
            appleVolume = Self.position(forGain: v)
            Self.defaults.set(appleVolume, forKey: "appleVolumePosition")
        }
    }

    func signInToAppleMusic() {
        Task {
            do { try await apple.authorize() } catch { note("Apple Music sign-in: \(error.localizedDescription)") }
        }
    }

    // MARK: Helpers

    func note(_ text: String) {
        if Self.debug { print("note: \(text)"); fflush(stdout) }
        log.append(LogLine(text: text))
        if log.count > 50 { log.removeFirst(log.count - 50) }
    }

    static func time(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
