import Foundation

public final class GmailAPIClient: GmailAPIClientProtocol, @unchecked Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func getProfile(accessToken: String) async throws -> GmailProfile {
        let url = baseURL.appendingPathComponent("profile")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try handleHTTPResponse(response, data: data)

        let decoder = JSONDecoder()
        return try decoder.decode(GmailProfile.self, from: data)
    }

    public func getInboxLabel(accessToken: String) async throws -> GmailLabel {
        let url = baseURL.appendingPathComponent("labels/INBOX")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try handleHTTPResponse(response, data: data)

        let decoder = JSONDecoder()
        return try decoder.decode(GmailLabel.self, from: data)
    }

    public func listHistory(
        accessToken: String,
        startHistoryId: String,
        pageToken: String?
    ) async throws -> GmailHistoryListResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("history"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId),
            URLQueryItem(name: "historyTypes", value: "messageAdded")
        ]
        if let token = pageToken, !token.isEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: token))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw GmailAPIError.networkError("无效 URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            // Expired startHistoryId
            throw GmailAPIError.historyIdExpired(startHistoryId: startHistoryId)
        }
        try handleHTTPResponse(response, data: data)

        let decoder = JSONDecoder()
        return try decoder.decode(GmailHistoryListResponse.self, from: data)
    }

    public func getMessage(accessToken: String, messageId: String) async throws -> GmailMessage? {
        var components = URLComponents(url: baseURL.appendingPathComponent("messages/\(messageId)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "format", value: "minimal"),
            URLQueryItem(name: "fields", value: "id,labelIds")
        ]
        guard let url = components.url else {
            throw GmailAPIError.networkError("无效 URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return nil
        }
        try handleHTTPResponse(response, data: data)

        let decoder = JSONDecoder()
        return try decoder.decode(GmailMessage.self, from: data)
    }

    private func handleHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GmailAPIError.networkError("响应格式错误")
        }

        if http.statusCode == 401 {
            throw GmailAPIError.unauthorized
        }

        if http.statusCode == 429 || http.statusCode == 403 {
            var retrySeconds: TimeInterval?
            if let retryHeader = http.value(forHTTPHeaderField: "Retry-After"),
               let seconds = Double(retryHeader) {
                retrySeconds = seconds
            }
            throw GmailAPIError.rateLimited(retryAfter: retrySeconds)
        }

        if http.statusCode >= 500 {
            throw GmailAPIError.serverError(statusCode: http.statusCode)
        }

        guard (200...299).contains(http.statusCode) else {
            throw GmailAPIError.serverError(statusCode: http.statusCode)
        }
    }
}
