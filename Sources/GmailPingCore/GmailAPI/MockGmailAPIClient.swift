import Foundation

public actor MockGmailAPIClient: GmailAPIClientProtocol {
    public var profileResult: Result<GmailProfile, Error>?
    public var inboxLabelResult: Result<GmailLabel, Error>?
    public var historyResponses: [String: Result<GmailHistoryListResponse, Error>] = [:]
    public var messageResults: [String: Result<GmailMessage?, Error>] = [:]

    public private(set) var getProfileCallCount = 0
    public private(set) var getInboxLabelCallCount = 0
    public private(set) var listHistoryCallCount = 0
    public private(set) var getMessageCallCount = 0

    public init() {}

    public func setProfileResult(_ result: Result<GmailProfile, Error>) {
        self.profileResult = result
    }

    public func setInboxLabelResult(_ result: Result<GmailLabel, Error>) {
        self.inboxLabelResult = result
    }

    public func setHistoryResponse(
        startHistoryId: String,
        result: Result<GmailHistoryListResponse, Error>
    ) {
        historyResponses[startHistoryId] = result
    }

    public func setMessage(id: String, labelIds: [String]?) {
        messageResults[id] = .success(GmailMessage(id: id, labelIds: labelIds))
    }

    public func setMessageResult(id: String, result: Result<GmailMessage?, Error>) {
        messageResults[id] = result
    }

    public func getProfile(accessToken: String) async throws -> GmailProfile {
        getProfileCallCount += 1
        if let res = profileResult {
            return try res.get()
        }
        return GmailProfile(emailAddress: "test@example.com", historyId: "100")
    }

    public func getInboxLabel(accessToken: String) async throws -> GmailLabel {
        getInboxLabelCallCount += 1
        if let res = inboxLabelResult {
            return try res.get()
        }
        return GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 0)
    }

    public func listHistory(
        accessToken: String,
        startHistoryId: String,
        pageToken: String?
    ) async throws -> GmailHistoryListResponse {
        listHistoryCallCount += 1
        let key = pageToken != nil ? "\(startHistoryId)_\(pageToken!)" : startHistoryId
        let res = historyResponses[key] ?? historyResponses[startHistoryId] ?? historyResponses["default"]

        if let res = res {
            return try res.get()
        }
        return GmailHistoryListResponse(history: [], nextPageToken: nil, historyId: startHistoryId)
    }

    public func getMessage(accessToken: String, messageId: String) async throws -> GmailMessage? {
        getMessageCallCount += 1
        let res = messageResults[messageId]

        if let res = res {
            return try res.get()
        }
        return GmailMessage(id: messageId, labelIds: ["INBOX"])
    }
}
