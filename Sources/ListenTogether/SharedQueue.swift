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
