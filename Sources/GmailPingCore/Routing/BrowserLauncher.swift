import Foundation
import AppKit

public protocol BrowserLauncherProtocol: Sendable {
    func openURL(_ url: URL) -> Bool
    func openInbox(for email: String) -> Bool
}

public struct BrowserURLBuilder {
    public static func makeInboxURL(for email: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: allowed) ?? email
        let urlString = "https://mail.google.com/mail/?authuser=\(encodedEmail)#inbox"
        return URL(string: urlString)!
    }
}

public final class DefaultBrowserLauncher: BrowserLauncherProtocol, @unchecked Sendable {
    public init() {}

    @discardableResult
    public func openURL(_ url: URL) -> Bool {
        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    public func openInbox(for email: String) -> Bool {
        let url = BrowserURLBuilder.makeInboxURL(for: email)
        return openURL(url)
    }
}

public final class MockBrowserLauncher: BrowserLauncherProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var openedURLs: [URL] = []
    public private(set) var openedEmails: [String] = []

    public init() {}

    @discardableResult
    public func openURL(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openedURLs.append(url)
        return true
    }

    @discardableResult
    public func openInbox(for email: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openedEmails.append(email)
        let url = BrowserURLBuilder.makeInboxURL(for: email)
        openedURLs.append(url)
        return true
    }
}
