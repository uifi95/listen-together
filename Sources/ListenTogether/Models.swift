import Foundation

enum MusicService: String, Codable, CaseIterable, Identifiable {
    case appleMusic
    case qobuz

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .qobuz: return "Qobuz"
        }
    }
}

/// A track as one service knows it. `id` (and `albumId` for Qobuz) only mean
/// something on `service`; the rest is used to find it on the other service.
struct TrackInfo: Codable, Equatable {
    var service: MusicService
    var id: String
    var albumId: String?
    var title: String
    var artist: String
    var album: String
    var isrc: String?
    var durationMs: Int

    var summary: String { artist.isEmpty ? title : "\(title) — \(artist)" }
}

/// What a local player reports.
struct PlayerSnapshot: Equatable {
    var ready = true
    var authorized = true
    var track: TrackInfo?
    var playing = false
    var positionMs = 0
    var loading = false
    /// 0...1, for players whose volume the app controls (Apple Music).
    var volume: Double?
    /// Changes whenever the app's own play queue changes.
    var queueVersion: Int?
}

/// The room's shared timeline: what is playing, and where it was at `at`
/// (milliseconds on the relay's clock).
struct SharedState: Codable, Equatable {
    var track: TrackInfo?
    var playing: Bool
    var positionMs: Int
    var at: Double
    var from: String?
    var fromName: String?
    /// The shared queue (optional: older versions of the app don't send it).
    var queue: [QueueItem]?
    var removed: [String]?

    func expectedPosition(atRelayTime now: Double) -> Int {
        guard playing else { return positionMs }
        var pos = positionMs + Int(max(0, now - at))
        if let d = track?.durationMs, d > 0 { pos = min(pos, d) }
        return pos
    }
}

@MainActor
protocol MusicPlayer: AnyObject {
    var service: MusicService { get }
    func connect() async throws
    func snapshot() async throws -> PlayerSnapshot
    func play() async throws
    func pause() async throws
    func seek(toMs ms: Int) async throws
    /// Candidates on this service for a track from (usually) the other one.
    func candidates(for track: TrackInfo) async throws -> [TrackInfo]
    /// Start `track` (a track of this service) at `positionMs`.
    func load(_ track: TrackInfo, positionMs: Int, play: Bool) async throws
    /// Keys of the items in the app's own play queue, in play order.
    func queueKeys() async throws -> [String]
    /// Tracks for queue keys; nil for items whose details haven't loaded yet.
    func queueTracks(_ keys: [String]) async throws -> [String: TrackInfo?]
    /// How the app said an item was added (true = Play Next), when it says;
    /// valid for keys from the last `queueTracks` call. Otherwise the
    /// engine guesses from where the item landed.
    func addedAsPlayNext(_ key: String) -> Bool?
}

extension MusicPlayer {
    func addedAsPlayNext(_ key: String) -> Bool? { nil }
}

struct PlayerError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Matcher {
    /// Lowercased title or name without bracketed parts, "- Remastered"
    /// style suffixes, "feat." credits and punctuation.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+-\s+.*$"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(feat\.?|ft\.?|featuring)\s.*$"#, with: " ", options: .regularExpression)
        t = t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func artists(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: #"\b(feat\.?|ft\.?|featuring|with)\b"#, with: ",", options: .regularExpression)
            .split(whereSeparator: { ",&;/".contains($0) })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// How alike two tracks are. 5 or more counts as the same recording.
    static func score(_ a: TrackInfo, _ b: TrackInfo) -> Double {
        var s = 0.0
        if let x = a.isrc, let y = b.isrc, !x.isEmpty, x.caseInsensitiveCompare(y) == .orderedSame { s += 4 }

        let ta = normalize(a.title), tb = normalize(b.title)
        if !ta.isEmpty && ta == tb { s += 3 }
        else if !ta.isEmpty && !tb.isEmpty && (ta.contains(tb) || tb.contains(ta)) { s += 1.5 }

        let aa = artists(a.artist), ab = artists(b.artist)
        if !aa.isEmpty && !ab.isEmpty {
            if aa.contains(where: { x in ab.contains(where: { y in x == y || x.contains(y) || y.contains(x) }) }) { s += 2 }
            else { s -= 2 }
        }

        if a.durationMs > 0 && b.durationMs > 0 {
            let diff = abs(a.durationMs - b.durationMs)
            if diff <= 2500 { s += 2 } else if diff <= 6000 { s += 1 } else if diff > 20000 { s -= 3 }
        }

        // A live or remixed version is not the studio recording.
        for tag in ["live", "remix", "acoustic", "instrumental", "karaoke", "demo"] {
            if a.title.lowercased().contains(tag) != b.title.lowercased().contains(tag) { s -= 1.5; break }
        }
        return s
    }

    static func isSame(_ a: TrackInfo?, _ b: TrackInfo?) -> Bool {
        guard let a, let b else { return false }
        if a.service == b.service && a.id == b.id { return true }
        return score(a, b) >= 5
    }

    static func best(for target: TrackInfo, in candidates: [TrackInfo]) -> TrackInfo? {
        candidates
            .map { (track: $0, score: score(target, $0)) }
            .filter { $0.score >= 5 }
            .max { l, r in
                if l.score != r.score { return l.score < r.score }
                return abs(l.track.durationMs - target.durationMs) > abs(r.track.durationMs - target.durationMs)
            }?.track
    }

    static func searchQuery(for t: TrackInfo) -> String {
        let artist = artists(t.artist).first ?? normalize(t.artist)
        return "\(artist) \(normalize(t.title))".trimmingCharacters(in: .whitespaces)
    }
}
