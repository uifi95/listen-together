import XCTest
@testable import ListenTogether

final class QueueMirrorTests: XCTestCase {
    private func song(_ id: String, _ service: MusicService = .qobuz) -> TrackInfo {
        TrackInfo(service: service, id: id, albumId: "al", title: "Song \(id)", artist: "A", album: "", isrc: nil, durationMs: 200_000)
    }

    private func item(_ id: String, next: Bool = false) -> QueueItem {
        QueueItem(id: id, track: song(id), addedBy: "x", addedAt: 0, seq: 0, playNext: next)
    }

    private func mirror(_ pairs: [String: String]) -> QueueMirror {
        var m = QueueMirror()
        m.keyFor = pairs
        for id in pairs.keys { m.resolved[id] = song(id) }
        return m
    }

    func testCopyThatStartsPlayingIsPlayed() {
        var m = mirror(["X": "k2", "Y": "k3"])
        let before = AppQueue(keys: ["k1", "k2", "k3"], upcoming: ["k2", "k3"], current: "k1")
        let after = AppQueue(keys: ["k1", "k2", "k3"], upcoming: ["k3"], current: "k2")
        let change = m.update(previous: before, current: after)
        XCTAssertEqual(change, QueueMirror.Change(played: ["X"]))
        XCTAssertEqual(m.keyFor, ["Y": "k3"])
    }

    func testCopyTakenOutIsRemoved() {
        var m = mirror(["X": "k2", "Y": "k3"])
        let before = AppQueue(keys: ["k1", "k2", "k3"], upcoming: ["k2", "k3"], current: "k1")
        let after = AppQueue(keys: ["k1", "k3"], upcoming: ["k3"], current: "k1")
        XCTAssertEqual(m.update(previous: before, current: after), QueueMirror.Change(removed: ["X"]))
    }

    func testJumpingPastACopySkipsIt() {
        var m = mirror(["X": "k2", "Y": "k3"])
        let before = AppQueue(keys: ["k1", "k2", "k3"], upcoming: ["k2", "k3"], current: "k1")
        let after = AppQueue(keys: ["k1", "k2", "k3"], upcoming: [], current: "k3")
        XCTAssertEqual(m.update(previous: before, current: after), QueueMirror.Change(played: ["Y"], skipped: ["X"]))
    }

    /// A new song or album replaced the queue: nobody removed anything; the
    /// copies are forgotten so they get added again.
    func testReplacedQueueRemovesNothing() {
        var m = mirror(["X": "k2"])
        let before = AppQueue(keys: ["k1", "k2"], upcoming: ["k2"], current: "k1")
        let after = AppQueue(keys: ["n1"], upcoming: [], current: "n1")
        XCTAssertEqual(m.update(previous: before, current: after), QueueMirror.Change(replaced: true))
        XCTAssertTrue(m.keyFor.isEmpty)
        XCTAssertEqual(m.missing(from: [item("X")]).map(\.id), ["X"])
    }

    func testOwnCopyIsClaimedByTrackId() {
        var m = QueueMirror()
        m.pending["X"] = ("t42", Date())
        XCTAssertNil(m.claim(trackId: "t7", key: "k9"))
        XCTAssertEqual(m.claim(trackId: "t42", key: "k9"), "X")
        XCTAssertEqual(m.keyFor["X"], "k9")
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.sharedId(forKey: "k9"), "X")
    }

    func testMissingSkipsCopiedPendingAndUnavailable() {
        var m = mirror(["A": "k1"])
        m.pending["B"] = ("b", Date())
        m.unavailable = ["C"]
        XCTAssertEqual(m.missing(from: [item("A"), item("B"), item("C"), item("D")]).map(\.id), ["D"])
    }

    func testExtraCopiesAreRemovedButNotTheSongAboutToPlay() {
        let m = mirror(["X": "k2", "Y": "k3", "Z": "k4"])
        let app = AppQueue(keys: ["k1", "k2", "k3", "k4"], upcoming: ["k2", "k3", "k4"], current: "k1")
        // X and Y left the room's queue; Y is the song the room plays now.
        let extra = m.extra(in: [item("Z")], app: app, keep: [song("Y")])
        XCTAssertEqual(extra.map(\.id), ["X"])
        XCTAssertEqual(extra.map(\.key), ["k2"])
    }

    func testPendingCopiesAreRetriedThenGivenUp() {
        var m = QueueMirror()
        let old = Date().addingTimeInterval(-QueueMirror.pendingTimeout - 1)
        m.pending["X"] = ("x", old)
        m.attempts["X"] = 1
        XCTAssertEqual(m.expirePending(), [])
        XCTAssertEqual(m.missing(from: [item("X")]).map(\.id), ["X"])  // tried again
        m.pending["X"] = ("x", old)
        m.attempts["X"] = QueueMirror.maxAttempts
        XCTAssertEqual(m.expirePending(), ["X"])
        XCTAssertTrue(m.missing(from: [item("X")]).isEmpty)
    }
}
