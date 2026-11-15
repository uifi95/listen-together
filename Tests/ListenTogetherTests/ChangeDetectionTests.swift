import XCTest
@testable import ListenTogether

final class ChangeDetectionTests: XCTestCase {
    private func song(_ id: String) -> TrackInfo {
        TrackInfo(service: .appleMusic, id: id, albumId: nil, title: id, artist: "A", album: "", isrc: nil, durationMs: 200_000)
    }

    /// Nothing playing, then a song that loads for a few ticks: the baseline
    /// must stay "nothing" until it plays, or the new song is never sent.
    func testFirstSongInIdleRoomIsNoticedAfterLoading() {
        let idle = PlayerSnapshot(track: nil)
        let loading = PlayerSnapshot(track: song("x"), playing: false, loading: true)
        XCTAssertTrue(SyncEngine.waitsForLoad(base: idle, snap: loading))
        XCTAssertTrue(SyncEngine.waitsForLoad(base: nil, snap: loading))
        let playing = PlayerSnapshot(track: song("x"), playing: true)
        XCTAssertFalse(SyncEngine.waitsForLoad(base: idle, snap: playing))
    }

    func testSwitchingSongsWaitsForTheNewOneToLoad() {
        let a = PlayerSnapshot(track: song("a"), playing: true, positionMs: 50_000)
        XCTAssertTrue(SyncEngine.waitsForLoad(base: a, snap: PlayerSnapshot(track: song("b"), playing: true, loading: true)))
    }

    /// Buffering in the same song keeps the old behaviour (baseline moves on).
    func testStallInSameSongDoesNotHoldTheBaseline() {
        let a = PlayerSnapshot(track: song("a"), playing: true, positionMs: 50_000)
        XCTAssertFalse(SyncEngine.waitsForLoad(base: a, snap: PlayerSnapshot(track: song("a"), playing: true, positionMs: 50_400, loading: true)))
    }
}
