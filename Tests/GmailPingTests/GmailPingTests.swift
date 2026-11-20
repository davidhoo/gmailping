import XCTest
@testable import GmailPingCore

final class GmailPingTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(GmailPingVersion.current, "1.1.0")
    }
}
