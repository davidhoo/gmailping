import Foundation

public struct DesktopOAuthConfiguration: Codable, Sendable {
    let clientId: String
    let clientSecret: String?

    private enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }

    private struct Export: Decodable {
        let installed: DesktopOAuthConfiguration
    }

    static var localFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gmailping/config.json")
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        file: URL = localFile,
        bundledFile: URL? = Bundle.main.url(forResource: "GoogleDesktopClient", withExtension: "json")
    ) throws -> Self {
        if let id = environment["GMAILPING_CLIENT_ID"], !id.isEmpty {
            return try Self(clientId: id, clientSecret: environment["GMAILPING_CLIENT_SECRET"]).validated()
        }
        if FileManager.default.fileExists(atPath: file.path) {
            return try decode(Data(contentsOf: file), allowLegacy: true)
        }
        if let bundledFile {
            return try decode(Data(contentsOf: bundledFile), allowLegacy: false)
        }
        throw OAuthError.missingClientConfiguration
    }

    private func validated() throws -> Self {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"),
              id.count > ".apps.googleusercontent.com".count,
              id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw OAuthError.invalidClientConfiguration
        }
        return Self(clientId: id, clientSecret: clientSecret)
    }

    private static func decode(_ data: Data, allowLegacy: Bool) throws -> Self {
        let decoder = JSONDecoder()
        if let export = try? decoder.decode(Export.self, from: data) {
            return try export.installed.validated()
        }
        if allowLegacy, let flat = try? decoder.decode(Self.self, from: data) {
            return try flat.validated()
        }
        throw OAuthError.invalidClientConfiguration
    }

    public static var setupIssue: String? {
        do {
            _ = try load()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
