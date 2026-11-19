import Foundation
import CryptoKit

public struct PKCE {
    public static func generateRandomString(length: Int = 43) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        let base64 = Data(bytes).base64EncodedString()
        return base64URLSafe(base64)
    }

    public static func generateCodeVerifier() -> String {
        return generateRandomString(length: 64)
    }

    public static func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else {
            return ""
        }
        let hash = SHA256.hash(data: data)
        let base64 = Data(hash).base64EncodedString()
        return base64URLSafe(base64)
    }

    public static func base64URLSafe(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
