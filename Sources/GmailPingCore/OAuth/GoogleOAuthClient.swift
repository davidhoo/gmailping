import Foundation

public enum OAuthError: Error, LocalizedError, Equatable {
    case invalidRedirectURI
    case stateMismatch
    case missingCode
    case missingIDToken
    case invalidIDToken
    case nonceMismatch
    case subMismatch(expected: String, actual: String)
    case missingRefreshToken
    case serverError(statusCode: Int, message: String)
    case invalidGrant
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRedirectURI:
            return "无效的重定向地址"
        case .stateMismatch:
            return "OAuth state 校验失败，可能存在跨站请求伪造风险"
        case .missingCode:
            return "未能从 Google 回调中获取授权码"
        case .missingIDToken:
            return "授权响应缺少 ID Token"
        case .invalidIDToken:
            return "ID Token 格式或签名校验失败"
        case .nonceMismatch:
            return "ID Token nonce 不匹配"
        case .subMismatch(let expected, let actual):
            return "Google 账号不匹配：预期 sub 为 \(expected)，实际为 \(actual)。请选择原账号重新授权。"
        case .missingRefreshToken:
            return "未获取到可持续刷新的 Refresh Token，请重新授权并勾选权限"
        case .serverError(let code, let msg):
            return "Google 授权服务器返回错误 (\(code)): \(msg)"
        case .invalidGrant:
            return "授权已失效或被撤销，需要重新授权"
        case .networkError(let msg):
            return "网络错误: \(msg)"
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

public final class GoogleOAuthClient: GoogleOAuthClientProtocol, @unchecked Sendable {
    public let clientId: String
    public let clientSecret: String?
    private let session: URLSession

    public init(
        clientId: String = "GMAILPING_CLIENT_ID",
        clientSecret: String? = nil,
        session: URLSession = .shared
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.session = session
    }

    public func buildAuthorizationURL(
        state: String,
        nonce: String,
        codeChallenge: String,
        redirectURI: String,
        loginHint: String? = nil
    ) -> URL? {
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

        var bodyParams: [String: String] = [
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        if let clientSecret = clientSecret {
            bodyParams["client_secret"] = clientSecret
        }

        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
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

        let parsedIDToken = try parseAndValidateIDToken(idToken, expectedNonce: expectedNonce)

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

        var bodyParams: [String: String] = [
            "refresh_token": currentRefreshToken,
            "client_id": clientId,
            "grant_type": "refresh_token"
        ]
        if let clientSecret = clientSecret {
            bodyParams["client_secret"] = clientSecret
        }

        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
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
            throw OAuthError.invalidIDToken
        }

        let newRefreshToken = json["refresh_token"] as? String
        return (accessToken, newRefreshToken, Date().addingTimeInterval(expiresIn))
    }

    public func parseAndValidateIDToken(_ idToken: String, expectedNonce: String?) throws -> (sub: String, email: String?) {
        let parts = idToken.components(separatedBy: ".")
        guard parts.count == 3 else {
            throw OAuthError.invalidIDToken
        }

        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else {
            throw OAuthError.invalidIDToken
        }

        if let expectedNonce = expectedNonce, let tokenNonce = json["nonce"] as? String {
            guard tokenNonce == expectedNonce else {
                throw OAuthError.nonceMismatch
            }
        }

        let email = json["email"] as? String
        return (sub, email)
    }
}
