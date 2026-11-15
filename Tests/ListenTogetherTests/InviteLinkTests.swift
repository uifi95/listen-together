import XCTest
@testable import ListenTogether

final class InviteLinkTests: XCTestCase {
    func testHttpsInvite() {
        let r = InviteLink.parse("https://oops-dublin.trycloudflare.com/join/amber-tide-42-kqxzp")
        XCTAssertEqual(r?.relay, "https://oops-dublin.trycloudflare.com")
        XCTAssertEqual(r?.room, "amber-tide-42-kqxzp")
    }

    func testAppLinkAndWhitespace() {
        let r = InviteLink.parse("  listentogether://join?relay=https://x.trycloudflare.com&room=nova-pine-10-abcde\n")
        XCTAssertEqual(r?.relay, "https://x.trycloudflare.com")
        XCTAssertEqual(r?.room, "nova-pine-10-abcde")
    }

    func testRejectsOtherLinks() {
        XCTAssertNil(InviteLink.parse("https://example.com/"))
        XCTAssertNil(InviteLink.parse("https://example.com/join"))
        XCTAssertNil(InviteLink.parse("hello"))
        XCTAssertNil(InviteLink.parse("listentogether://join?room=only-room"))
    }

    func testRelayURLFromInvite() {
        let url = RelayClient.makeURL(base: "https://x.trycloudflare.com", room: "Nova-Pine", name: "Sam")
        XCTAssertEqual(url?.absoluteString, "wss://x.trycloudflare.com/?room=nova-pine&name=Sam")
    }
}
