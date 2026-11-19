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
    public var autoCallback: Bool = false

    public init() {}

    @discardableResult
    public func openURL(_ url: URL) -> Bool {
        lock.lock()
        openedURLs.append(url)
        let shouldAuto = autoCallback
        lock.unlock()

        if shouldAuto, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value ?? ""
            if let redirectURL = URL(string: "\(redirectURI)?code=test_code&state=\(state)") {
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    _ = try? await URLSession.shared.data(from: redirectURL)
                }
            }
        }

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
