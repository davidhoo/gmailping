import Foundation
import ServiceManagement

public protocol LoginItemManagerProtocol: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public final class LoginItemManager: LoginItemManagerProtocol, @unchecked Sendable {
    public init() {}

    public var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
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
    private var state: Bool

    public init(initialState: Bool = false) {
        self.state = initialState
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func setEnabled(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        state = enabled
    }
}
