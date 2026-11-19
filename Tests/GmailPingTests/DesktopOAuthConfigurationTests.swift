import XCTest
@testable import GmailPingCore

final class DesktopOAuthConfigurationTests: XCTestCase {
    func testMissingAndPlaceholderClientFailLocally() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try DesktopOAuthConfiguration.load(environment: [:], file: missing, bundledFile: nil)) {
            XCTAssertEqual($0 as? OAuthError, .missingClientConfiguration)
        }
        XCTAssertThrowsError(try DesktopOAuthConfiguration.load(
            environment: ["GMAILPING_CLIENT_ID": "GMAILPING_CLIENT_ID"], file: missing, bundledFile: nil
        )) {
            XCTAssertEqual($0 as? OAuthError, .invalidClientConfiguration)
        }
    }

    func testCleanInstallUsesPublisherClientAndPreservesExistingOverrides() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = directory.appendingPathComponent("GoogleDesktopClient.json")
        let local = directory.appendingPathComponent("config.json")
        let fields = ["client_id": "123-publisher.apps.googleusercontent.com", "client_secret": "fixture"]
        try JSONSerialization.data(withJSONObject: ["installed": fields]).write(to: resource)
        let saved = try DesktopOAuthConfiguration.load(environment: [:], file: local, bundledFile: resource)
        XCTAssertEqual(saved.clientId, fields["client_id"])
        XCTAssertEqual(saved.clientSecret, fields["client_secret"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))

        try JSONSerialization.data(withJSONObject: ["web": fields]).write(to: resource)
        XCTAssertThrowsError(try DesktopOAuthConfiguration.load(environment: [:], file: local, bundledFile: resource))
        let oldId = "456-legacy.apps.googleusercontent.com"
        try JSONSerialization.data(withJSONObject: ["client_id": oldId]).write(to: local)
        let legacy = try DesktopOAuthConfiguration.load(environment: [:], file: local, bundledFile: resource)
        XCTAssertEqual(legacy.clientId, oldId)
    }
}
