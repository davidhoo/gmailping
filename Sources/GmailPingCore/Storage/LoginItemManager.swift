import Foundation
import ServiceManagement

public enum LoginItemStatus: String, Sendable {
    case enabled = "已开启"
    case requiresApproval = "待系统设置批准"
    case notRegistered = "未开启"
    case unsupported = "不支持"
}

public protocol LoginItemManagerProtocol: Sendable {
    var status: LoginItemStatus { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public final class LoginItemManager: LoginItemManagerProtocol, @unchecked Sendable {
    public init() {}

    public static func detectIsSystemLoginLaunch(event: NSAppleEventDescriptor? = nil) -> Bool {
        let currentEvent = event ?? NSAppleEventManager.shared().currentAppleEvent
        guard let currentEvent = currentEvent else { return false }
        if let prop = currentEvent.paramDescriptor(forKeyword: keyAEPropData) {
            let enumCode = prop.enumCodeValue
            if enumCode == 0x6c676974 /* 'lgit' (keyAELaunchedAsLogInItem) */ {
                return true
            }
        }
        return false
    }

    public var status: LoginItemStatus {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return .enabled
            case .requiresApproval:
                return .requiresApproval
            case .notRegistered, .notFound:
                return .notRegistered
            @unknown default:
                return .unsupported
            }
        }
        return .unsupported
    }

    public var isEnabled: Bool {
        return status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        }
    }
}

public final class MockLoginItemManager: LoginItemManagerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var mockStatus: LoginItemStatus
    public var shouldThrowOnSetEnabled: Bool = false

    public init(initialStatus: LoginItemStatus = .notRegistered) {
        self.mockStatus = initialStatus
    }

    public var status: LoginItemStatus {
        lock.lock()
        defer { lock.unlock() }
        return mockStatus
    }

    public var isEnabled: Bool {
        return status == .enabled
    }

    public func setStatus(_ newStatus: LoginItemStatus) {
        lock.lock()
        defer { lock.unlock() }
        mockStatus = newStatus
    }

    public func setEnabled(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldThrowOnSetEnabled {
            throw NSError(domain: "SMAppServiceError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated registration failure"])
        }
        mockStatus = enabled ? .enabled : .notRegistered
    }
}
