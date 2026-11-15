import XCTest
@testable import ListenTogether

final class MatcherTests: XCTestCase {
    private func t(_ service: MusicService, _ id: String, _ title: String, _ artist: String,
                   _ isrc: String?, _ ms: Int) -> TrackInfo {
        TrackInfo(service: service, id: id, albumId: nil, title: title, artist: artist, album: "", isrc: isrc, durationMs: ms)
    }

    func testPicksOriginalOverCoverWithSameISRC() {
        // Real results: Apple's ISRC filter also returns a cover that reuses the code.
        let qobuz = t(.qobuz, "33978481", "Paranoid Android", "Radiohead", "GBAYE9701376", 387213)
        let candidates = [
            t(.appleMusic, "1743475837", "Paranoid Android (Guitar and Vocal Duo Version)", "Malaka Akustika", "GBAYE9701376", 284300),
            t(.appleMusic, "1097861770", "Paranoid Android", "Radiohead", "GBAYE9701376", 387213),
        ]
        XCTAssertEqual(Matcher.best(for: qobuz, in: candidates)?.id, "1097861770")
    }

    func testMatchesRemasterWithoutISRC() {
        let apple = t(.appleMusic, "1", "Paranoid Android", "Radiohead", nil, 387000)
        let qobuz = t(.qobuz, "2", "Paranoid Android (Remastered)", "Radiohead", "GBBKS1700185", 383000)
        XCTAssertTrue(Matcher.isSame(apple, qobuz))
    }

    func testRejectsLiveVersionAndOtherSongs() {
        let studio = t(.qobuz, "1", "Paranoid Android", "Radiohead", "A", 387000)
        let live = t(.appleMusic, "2", "Paranoid Android (Live)", "Radiohead", "B", 399000)
        let other = t(.appleMusic, "3", "Karma Police", "Radiohead", "C", 264000)
        XCTAssertNil(Matcher.best(for: studio, in: [live, other]))
    }

    func testFeaturedArtistsAndAccents() {
        let a = t(.appleMusic, "1", "Señorita", "Shawn Mendes & Camila Cabello", nil, 191000)
        let b = t(.qobuz, "2", "Senorita", "Shawn Mendes, Camila Cabello", nil, 190800)
        XCTAssertTrue(Matcher.isSame(a, b))
    }

    func testExpectedPosition() {
        let s = SharedState(track: t(.qobuz, "1", "x", "y", nil, 100_000), playing: true, positionMs: 10_000, at: 1_000_000)
        XCTAssertEqual(s.expectedPosition(atRelayTime: 1_002_500), 12_500)
        XCTAssertEqual(s.expectedPosition(atRelayTime: 2_000_000), 100_000) // clamps at the end
        var paused = s; paused.playing = false
        XCTAssertEqual(paused.expectedPosition(atRelayTime: 1_002_500), 10_000)
    }
}

final class VolumeCurveTests: XCTestCase {
    func testCubicTaper() {
        XCTAssertEqual(SyncEngine.gain(forPosition: 1), 1)
        XCTAssertEqual(SyncEngine.gain(forPosition: 0), 0)
        XCTAssertEqual(SyncEngine.gain(forPosition: 0.5), 0.125, accuracy: 1e-9)      // ≈ −18 dB
        XCTAssertEqual(20 * log10(SyncEngine.gain(forPosition: 0.5)), -18.06, accuracy: 0.01)
        XCTAssertEqual(SyncEngine.position(forGain: SyncEngine.gain(forPosition: 0.37)), 0.37, accuracy: 1e-9)
    }
}
