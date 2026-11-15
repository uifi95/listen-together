import Foundation

/// A song someone queued in their own app (Qobuz or Apple Music), kept in
/// the room's shared queue.
struct QueueItem: Codable, Equatable, Identifiable {
    var id: String
    var track: TrackInfo
    var addedBy: String
    /// When it was queued, on the relay's clock.
    var addedAt: Double
    /// Position within one queueing action (an album queued at once).
    var seq: Int
    /// Queued with "Play Next" rather than "Add to Queue".
    var playNext: Bool
}

/// The shared queue. Everyone holds a copy and copies merge: an item is in
/// the queue if anyone added it and nobody removed it (played, skipped or
/// deleted). Order is computed, not stored, so all copies agree on it no
/// matter in which order the changes arrived:
/// - "Play Next" items first, the most recent one first (as both apps do),
/// - then "Add to Queue" items, oldest first.
struct SharedQueue: Equatable {
    private(set) var items: [QueueItem] = []
    private(set) var removed: [String] = []

    static let removedMemory = 500

    var isEmpty: Bool { items.isEmpty }
    var first: QueueItem? { items.first }

    static func ordered(_ a: QueueItem, _ b: QueueItem) -> Bool {
        if a.playNext != b.playNext { return a.playNext }
        if a.addedAt != b.addedAt { return a.playNext ? a.addedAt > b.addedAt : a.addedAt < b.addedAt }
        if a.seq != b.seq { return a.seq < b.seq }
        return a.id < b.id
    }

    /// Returns the items that were new to this copy.
    @discardableResult
    mutating func merge(items incoming: [QueueItem], removed incomingRemoved: [String]) -> [QueueItem] {
        for id in incomingRemoved where !removed.contains(id) { removed.append(id) }
        if removed.count > Self.removedMemory { removed.removeFirst(removed.count - Self.removedMemory) }
        let gone = Set(removed)
        let known = Set(items.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) && !gone.contains($0.id) }
        items = (items + fresh).filter { !gone.contains($0.id) }.sorted(by: Self.ordered)
        return fresh
    }

    mutating func add(_ new: [QueueItem]) { merge(items: new, removed: []) }

    mutating func remove(_ id: String) { merge(items: [], removed: [id]) }

    mutating func clear() { merge(items: [], removed: items.map(\.id)) }
}

/// One queueing action seen in an app's own queue.
struct QueueAddition: Equatable {
    var keys: [String]
    var playNext: Bool
}

enum QueueDiff {
    /// What was added between two snapshots of an app's queue (item keys in
    /// play order). A queue with nothing left of the previous one was
    /// replaced (someone started an album or song), which is not an addition.
    /// New items with older items after them were inserted ("Play Next");
    /// new items at the end were appended ("Add to Queue").
    static func additions(previous: [String], current: [String]) -> [QueueAddition] {
        guard !previous.isEmpty else { return [] }
        let prev = Set(previous)
        guard current.contains(where: prev.contains) else { return [] }
        var out: [QueueAddition] = []
        var run: [String] = []
        for key in current {
            if prev.contains(key) {
                if !run.isEmpty { out.append(QueueAddition(keys: run, playNext: true)) }
                run = []
            } else {
                run.append(key)
            }
        }
        if !run.isEmpty { out.append(QueueAddition(keys: run, playNext: false)) }
        return out
    }
}

/// Keeps track of which item in the app's own queue is the copy of which
/// shared queue item, so the two can be kept the same: songs queued in the
/// room are added to the app's queue, and songs removed, skipped or played
/// in the app leave the room's queue.
struct QueueMirror {
    /// Shared item id -> key of its copy in the app's queue.
    var keyFor: [String: String] = [:]
    /// The track on this service for each shared item.
    var resolved: [String: TrackInfo] = [:]
    /// Copies asked for but not seen in the app's queue yet (by local track
    /// id), with when they were asked for.
    var pending: [String: (trackId: String, since: Date)] = [:]
    var attempts: [String: Int] = [:]
    /// Items this service doesn't have, or that couldn't be added.
    var unavailable: Set<String> = []
    /// Copies of removed items that the app can't remove: skipped when
    /// they come up.
    var stale: Set<String> = []

    static let maxAttempts = 2
    static let pendingTimeout: TimeInterval = 20

    mutating func reset() { self = QueueMirror() }

    func sharedId(forKey key: String) -> String? {
        keyFor.first { $0.value == key }?.key
    }

    /// A new item of the app's queue with this track is the copy we asked
    /// for, if we did: returns that shared item's id.
    mutating func claim(trackId: String, key: String) -> String? {
        guard let id = pending.first(where: { $0.value.trackId == trackId })?.key else { return nil }
        pending[id] = nil
        keyFor[id] = key
        return id
    }

    /// What changed in the app's queue between two looks.
    struct Change: Equatable {
        /// The queue was replaced (a new album or song started): the copies
        /// are gone and get added again; nothing was removed by the user.
        var replaced = false
        /// Shared items whose copy is no longer upcoming, and why.
        var played: [String] = []    // now playing
        var skipped: [String] = []   // jumped past
        var removed: [String] = []   // taken out
    }

    /// Forgets copies that left the upcoming part of the app's queue and
    /// says which shared items that concerns.
    mutating func update(previous: AppQueue, current: AppQueue) -> Change {
        var change = Change()
        let now = Set(current.keys)
        if !previous.keys.isEmpty && !previous.keys.contains(where: now.contains) {
            change.replaced = true
            keyFor = keyFor.filter { now.contains($0.value) }
            return change
        }
        let upcoming = Set(current.upcoming)
        for (id, key) in keyFor.sorted(by: { $0.key < $1.key }) where !upcoming.contains(key) {
            keyFor[id] = nil
            if key == current.current { change.played.append(id) }
            else if now.contains(key) { change.skipped.append(id) }
            else { change.removed.append(id) }
        }
        return change
    }

    /// Shared items that have no copy in the app's queue yet, in queue order.
    func missing(from queue: [QueueItem]) -> [QueueItem] {
        queue.filter { keyFor[$0.id] == nil && pending[$0.id] == nil && !unavailable.contains($0.id) }
    }

    /// Copies (still upcoming in the app) of items no longer in the shared
    /// queue, except those for `keep` (the song about to play), which the
    /// engine jumps to instead.
    func extra(in queue: [QueueItem], app: AppQueue, keep: [TrackInfo?]) -> [(id: String, key: String)] {
        let ids = Set(queue.map(\.id))
        let upcoming = Set(app.upcoming)
        return keyFor.sorted(by: { $0.key < $1.key }).compactMap { id, key in
            guard !ids.contains(id), upcoming.contains(key) else { return nil }
            if let t = resolved[id], keep.contains(where: { Matcher.isSame($0, t) }) { return nil }
            return (id, key)
        }
    }

    /// Requests that never showed up: try again, up to `maxAttempts`.
    /// Returns the ids that gave up for good.
    mutating func expirePending(now: Date = Date()) -> [String] {
        var gaveUp: [String] = []
        for (id, p) in pending where now.timeIntervalSince(p.since) > Self.pendingTimeout {
            pending[id] = nil
            if attempts[id, default: 0] >= Self.maxAttempts {
                unavailable.insert(id)
                gaveUp.append(id)
            }
        }
        return gaveUp
    }
}
