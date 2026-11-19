import Foundation
import Security

public enum OAuthError: Error, LocalizedError, Equatable {
    case missingClientConfiguration
    case invalidClientConfiguration
    case invalidRedirectURI
    case stateMismatch
    case missingCode
    case missingIDToken
    case invalidIDToken(reason: String)
    case nonceMismatch
    case subMismatch(expected: String, actual: String, expectedEmail: String?)
    case missingRefreshToken
    case insufficientScopes(missing: [String])
    case serverError(statusCode: Int, message: String)
    case invalidGrant
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientConfiguration:
            return "此版本缺少 Google 登录配置。请联系 GmailPing 发布者获取已配置的版本。"
        case .invalidClientConfiguration:
            return "Google 登录配置无效。请联系 GmailPing 发布者。"
        case .invalidRedirectURI:
            return "无效的重定向地址"
        case .stateMismatch:
            return "OAuth state 校验失败，可能存在跨站请求伪造风险"
        case .missingCode:
            return "未能从 Google 回调中获取授权码"
        case .missingIDToken:
            return "授权响应缺少 ID Token"
        case .invalidIDToken(let reason):
            return "ID Token 校验失败: \(reason)"
        case .nonceMismatch:
            return "ID Token nonce 不匹配"
        case .subMismatch(let expected, let actual, let email):
            if let email = email {
                return "Google 账号不匹配：当前需要授权的是账号 \(email)（sub: \(expected)），但浏览器选择的账号对应 sub 为 \(actual)。请重新选择原账号。"
            }
            return "Google 账号不匹配：预期 sub 为 \(expected)，实际为 \(actual)。请选择原账号重新授权。"
        case .missingRefreshToken:
            return "未获取到可持续刷新的 Refresh Token，无法作为可用账号连接，请重新授权并在同意屏幕勾选权限"
        case .insufficientScopes(let missing):
            return "未授予必要权限: \(missing.joined(separator: ", "))"
        case .serverError(let code, let msg):
            return "Google 授权服务器返回错误 (\(code)): \(msg)"
        case .invalidGrant:
            return "授权已失效或被撤销，需要重新授权"
        case .networkError(let msg):
            return "网络异常: \(msg)"
        }
    }
}

public struct TokenExchangeResult: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let googleSub: String
    public let emailFromIdToken: String?
    public let grantedScopes: [String]

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        googleSub: String,
        emailFromIdToken: String? = nil,
        grantedScopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.googleSub = googleSub
        self.emailFromIdToken = emailFromIdToken
        self.grantedScopes = grantedScopes
    }
}

public protocol GoogleOAuthClientProtocol: Sendable {
    func validateConfiguration() throws
    func buildAuthorizationURL(
        state: String,
        nonce: String,
        codeChallenge: String,
        redirectURI: String,
        loginHint: String?
    ) -> URL?

    func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        expectedNonce: String
    ) async throws -> TokenExchangeResult

    func refreshToken(
        _ currentRefreshToken: String
    ) async throws -> (accessToken: String, newRefreshToken: String?, expiresAt: Date)
}

public extension GoogleOAuthClientProtocol {
    func validateConfiguration() throws {}
}

public final class GoogleOAuthClient: GoogleOAuthClientProtocol, @unchecked Sendable {
    private let explicitClientId: String?
    private let explicitClientSecret: String?
    private let session: URLSession
    public var publicKeyProvider: (@Sendable (String?) async throws -> SecKey?)?

    private func configuration() throws -> DesktopOAuthConfiguration {
        if let explicitClientId {
            return DesktopOAuthConfiguration(clientId: explicitClientId, clientSecret: explicitClientSecret)
        }
        let config = try DesktopOAuthConfiguration.load()
        return DesktopOAuthConfiguration(clientId: config.clientId, clientSecret: explicitClientSecret ?? config.clientSecret)
    }

    public init(
        clientId: String? = nil,
        clientSecret: String? = nil,
        session: URLSession = .shared
    ) {
        self.explicitClientId = clientId
        self.explicitClientSecret = clientSecret
        self.session = session
    }

    public static func resolveClientId() -> String {
        (try? DesktopOAuthConfiguration.load().clientId) ?? ""
    }

    public var clientId: String { (try? configuration().clientId) ?? "" }
    public var clientSecret: String? { try? configuration().clientSecret }

    public func validateConfiguration() throws {
        _ = try configuration()
    }

    public func buildAuthorizationURL(
        state: String,
        nonce: String,
        codeChallenge: String,
        redirectURI: String,
        loginHint: String? = nil
    ) -> URL? {
        guard let clientId = try? configuration().clientId else { return nil }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid https://www.googleapis.com/auth/gmail.metadata"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        if let loginHint = loginHint, !loginHint.isEmpty {
            queryItems.append(URLQueryItem(name: "login_hint", value: loginHint))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    public func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        expectedNonce: String
    ) async throws -> TokenExchangeResult {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw OAuthError.invalidRedirectURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let config = try configuration()
        var bodyParams: [String: String] = [
            "code": code,
            "client_id": config.clientId,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        if let clientSecret = config.clientSecret {
            bodyParams["client_secret"] = clientSecret
        }

        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.networkError("无效响应")
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errDesc = errorJson["error_description"] as? String ?? errorJson["error"] as? String {
                if errDesc == "invalid_grant" {
                    throw OAuthError.invalidGrant
                }
                throw OAuthError.serverError(statusCode: httpResponse.statusCode, message: errDesc)
            }
            throw OAuthError.serverError(statusCode: httpResponse.statusCode, message: "状态码 \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? TimeInterval,
              let idToken = json["id_token"] as? String else {
            throw OAuthError.missingIDToken
        }

        let refreshToken = json["refresh_token"] as? String
        let scopeString = json["scope"] as? String ?? ""
        let grantedScopes = scopeString.components(separatedBy: " ")

        // Check required scope
        let requiredScope = "https://www.googleapis.com/auth/gmail.metadata"
        if scopeString.isEmpty || !grantedScopes.contains(requiredScope) {
            throw OAuthError.insufficientScopes(missing: [requiredScope])
        }

        let parsedIDToken = try await parseAndValidateIDToken(idToken, expectedNonce: expectedNonce)

        return TokenExchangeResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            googleSub: parsedIDToken.sub,
            emailFromIdToken: parsedIDToken.email,
            grantedScopes: grantedScopes
        )
    }

    public func refreshToken(
        _ currentRefreshToken: String
    ) async throws -> (accessToken: String, newRefreshToken: String?, expiresAt: Date) {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw OAuthError.invalidRedirectURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let config = try configuration()
        var bodyParams: [String: String] = [
            "refresh_token": currentRefreshToken,
            "client_id": config.clientId,
            "grant_type": "refresh_token"
        ]
        if let clientSecret = config.clientSecret {
            bodyParams["client_secret"] = clientSecret
        }

        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Network failure during refresh MUST NOT be treated as invalidGrant!
            throw OAuthError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.networkError("无效响应")
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = errorJson["error"] as? String {
                if err == "invalid_grant" {
                    throw OAuthError.invalidGrant
                }
                let errDesc = errorJson["error_description"] as? String ?? err
                throw OAuthError.serverError(statusCode: httpResponse.statusCode, message: errDesc)
            }
            throw OAuthError.serverError(statusCode: httpResponse.statusCode, message: "状态码 \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? TimeInterval else {
            throw OAuthError.invalidIDToken(reason: "解析刷新令牌响应失败")
        }

        let newRefreshToken = json["refresh_token"] as? String
        return (accessToken, newRefreshToken, Date().addingTimeInterval(expiresIn))
    }

    public func parseAndValidateIDToken(
        _ idToken: String,
        expectedNonce: String?,
        publicKey: SecKey? = nil
    ) async throws -> (sub: String, email: String?) {
        let parts = idToken.components(separatedBy: ".")
        guard parts.count == 3 else {
            throw OAuthError.invalidIDToken(reason: "JWT 结构不合法，非三段式")
        }

        func decodeBase64URL(_ str: String) -> Data? {
            var base64 = str
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 {
                base64.append("=")
            }
            return Data(base64Encoded: base64)
        }

        // 1. Header validation
        guard let headerData = decodeBase64URL(parts[0]),
              let headerJson = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let alg = headerJson["alg"] as? String else {
            throw OAuthError.invalidIDToken(reason: "JWT Header 解析失败或缺少算法声明")
        }

        guard alg == "RS256" else {
            if alg == "none" {
                throw OAuthError.invalidIDToken(reason: "拒绝不安全的 'none' 算法")
            }
            throw OAuthError.invalidIDToken(reason: "仅支持 RS256 算法，不支持: \(alg)")
        }

        let kid = headerJson["kid"] as? String

        // 2. Signature presence validation
        guard let signatureData = decodeBase64URL(parts[2]), !signatureData.isEmpty else {
            throw OAuthError.invalidIDToken(reason: "JWT 签名缺失或无效")
        }

        // 3. Cryptographic RS256 signature verification
        guard let signedData = "\(parts[0]).\(parts[1])".data(using: .utf8) else {
            throw OAuthError.invalidIDToken(reason: "JWT 数据编码错误")
        }

        let targetKey: SecKey
        if let key = publicKey {
            targetKey = key
        } else if let provider = self.publicKeyProvider, let key = try await provider(kid) {
            targetKey = key
        } else if let fetchedKey = try await fetchGooglePublicKey(kid: kid) {
            targetKey = fetchedKey
        } else {
            throw OAuthError.invalidIDToken(reason: "未能获取有效的 Google RS256 公钥进行验签")
        }

        var verifyError: Unmanaged<CFError>?
        let isValid = SecKeyVerifySignature(
            targetKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signedData as CFData,
            signatureData as CFData,
            &verifyError
        )
        guard isValid else {
            throw OAuthError.invalidIDToken(reason: "RS256 签名校验失败")
        }

        // 4. Payload validation
        guard let payloadData = decodeBase64URL(parts[1]),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw OAuthError.invalidIDToken(reason: "JWT Payload 解析失败")
        }

        // Sub validation
        guard let sub = json["sub"] as? String, !sub.isEmpty else {
            throw OAuthError.invalidIDToken(reason: "缺少必填的 sub 身份标识")
        }

        // Issuer validation
        guard let iss = json["iss"] as? String else {
            throw OAuthError.invalidIDToken(reason: "缺少发行方 iss")
        }
        let validIssuers = ["https://accounts.google.com", "accounts.google.com"]
        guard validIssuers.contains(iss) else {
            throw OAuthError.invalidIDToken(reason: "发行方无效: \(iss)")
        }

        // Audience validation (must match configured client ID)
        guard let aud = json["aud"] as? String, !aud.isEmpty else {
            throw OAuthError.invalidIDToken(reason: "缺少受众 aud")
        }
        let clientId = try configuration().clientId
        guard aud == clientId else {
            throw OAuthError.invalidIDToken(reason: "受众 aud (\(aud)) 与客户端 ID (\(clientId)) 不匹配")
        }

        // Expiration validation (must exist and not be expired)
        guard let exp = json["exp"] as? TimeInterval else {
            throw OAuthError.invalidIDToken(reason: "缺少过期时间 exp")
        }
        guard exp > Date().timeIntervalSince1970 else {
            throw OAuthError.invalidIDToken(reason: "ID Token 已过期")
        }

        // Nonce validation
        if let expectedNonce = expectedNonce {
            guard let tokenNonce = json["nonce"] as? String, !tokenNonce.isEmpty else {
                throw OAuthError.invalidIDToken(reason: "缺少必填的 nonce 声明")
            }
            guard tokenNonce == expectedNonce else {
                throw OAuthError.nonceMismatch
            }
        }

        let email = json["email"] as? String
        return (sub, email)
    }

    private func fetchGooglePublicKey(kid: String?) async throws -> SecKey? {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v1/certs") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let certDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            return nil
        }
        let certString: String
        if let kid = kid, let specificCert = certDict[kid] {
            certString = specificCert
        } else if let firstCert = certDict.values.first {
            certString = firstCert
        } else {
            return nil
        }

        let cleaned = certString
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let certData = Data(base64Encoded: cleaned),
              let cert = SecCertificateCreateWithData(nil, certData as CFData),
              let key = SecCertificateCopyKey(cert) else {
            return nil
        }
        return key
    }
}
