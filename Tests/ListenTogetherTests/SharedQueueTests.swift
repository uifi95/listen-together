import XCTest
@testable import ListenTogether

final class QueueDiffTests: XCTestCase {
    func testAddToQueueAppends() {
        let adds = QueueDiff.additions(previous: ["a", "b"], current: ["a", "b", "c", "d"])
        XCTAssertEqual(adds, [QueueAddition(keys: ["c", "d"], playNext: false)])
    }

    func testPlayNextInserts() {
        // MusicKit's playNext with nothing playing put "Roads" first.
        let adds = QueueDiff.additions(previous: ["k1", "k2", "k3"], current: ["k4", "k1", "k2", "k3"])
        XCTAssertEqual(adds, [QueueAddition(keys: ["k4"], playNext: true)])
        // Qobuz inserts after the current item.
        let q = QueueDiff.additions(previous: ["q1|1|x", "q2|2|x", "q3|3|x"], current: ["q1|1|x", "q9|9|y", "q2|2|x", "q3|3|x"])
        XCTAssertEqual(q, [QueueAddition(keys: ["q9|9|y"], playNext: true)])
    }

    func testReplacedQueueIsNotAnAddition() {
        // Playing an album: Qobuz renumbers from q1 with a new context.
        XCTAssertEqual(QueueDiff.additions(previous: ["q1|1|x", "q2|2|x"], current: ["q1|7|z", "q2|8|z", "q3|9|z"]), [])
        XCTAssertEqual(QueueDiff.additions(previous: [], current: ["a"]), [])
    }

    func testRemovalIsNotAnAddition() {
        XCTAssertEqual(QueueDiff.additions(previous: ["a", "b", "c"], current: ["a", "c"]), [])
    }
}

final class SharedQueueTests: XCTestCase {
    private func item(_ id: String, at: Double, seq: Int = 0, next: Bool = false) -> QueueItem {
        QueueItem(id: id, track: TrackInfo(service: .qobuz, id: id, albumId: "al", title: id, artist: "A", album: "", isrc: nil, durationMs: 1000),
                  addedBy: "x", addedAt: at, seq: seq, playNext: next)
    }

    func testOrder() {
        var q = SharedQueue()
        q.add([item("add1", at: 1), item("add2", at: 2)])
        q.add([item("next1", at: 3, next: true)])
        q.add([item("next2a", at: 4, seq: 0, next: true), item("next2b", at: 4, seq: 1, next: true)])
        // Latest Play Next first (an album keeps its own order), then adds oldest first.
        XCTAssertEqual(q.items.map(\.id), ["next2a", "next2b", "next1", "add1", "add2"])
    }

    func testCopiesConvergeWhateverTheOrder() {
        // Both people queue at the same moment; their messages cross.
        var mine = SharedQueue(), theirs = SharedQueue()
        let a = item("mine", at: 10), b = item("theirs", at: 11)
        mine.add([a]); theirs.add([b])
        mine.merge(items: theirs.items, removed: theirs.removed)
        theirs.merge(items: [a], removed: [])
        XCTAssertEqual(mine, theirs)
        XCTAssertEqual(mine.items.map(\.id), ["mine", "theirs"])
    }

    func testRemovedStaysRemoved() {
        var q = SharedQueue()
        let a = item("a", at: 1)
        q.add([a])
        q.remove("a")            // played or deleted here
        q.merge(items: [a], removed: [])   // an older message still carries it
        XCTAssertTrue(q.isEmpty)
    }

    func testDecodesStateFromOlderVersion() throws {
        let json = #"{"track":null,"playing":false,"positionMs":0,"at":1}"#
        let s = try JSONDecoder().decode(SharedState.self, from: Data(json.utf8))
        XCTAssertNil(s.queue)
    }
}
