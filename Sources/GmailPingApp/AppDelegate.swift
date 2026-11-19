import AppKit
import SwiftUI
import GmailPingCore

public final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var manager: GmailPingManager!
    private var menuBarController: MenuBarController!
    private var preferencesWindow: NSWindow?

    public static func detectIsSystemLoginLaunch(event: NSAppleEventDescriptor? = nil) -> Bool {
        return LoginItemManager.detectIsSystemLoginLaunch(event: event)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Set as accessory application (no Dock icon, matches LSUIElement)
        NSApplication.shared.setActivationPolicy(.accessory)

        // Initialize Core Dependencies
        let accountStorage = AccountStorage()
        let keychainStorage = KeychainStorage()
        let preferencesStorage = UserDefaultsPreferencesStorage()
        let oauthClient = GoogleOAuthClient()
        let gmailClient = GmailAPIClient()
        let notificationService = NotificationService()
        let browserLauncher = DefaultBrowserLauncher()
        let loginItemManager = LoginItemManager()

        // Handle notification click:
        // "点击时重新解析实例。若账号已移除，打开账号管理。"
        notificationService.setNotificationClickHandler { [weak self, weak browserLauncher, accountStorage] accountId, email in
            Task { @MainActor [weak self, weak browserLauncher] in
                let isActive = (try? await accountStorage.isAccountActive(accountId: accountId)) ?? false
                if isActive {
                    _ = browserLauncher?.openInbox(for: email)
                } else {
                    self?.openPreferencesWindow()
                }
            }
        }

        let mgr = GmailPingManager(
            accountStorage: accountStorage,
            keychainStorage: keychainStorage,
            preferencesStorage: preferencesStorage,
            oauthClient: oauthClient,
            gmailClient: gmailClient,
            notificationService: notificationService,
            browserLauncher: browserLauncher,
            loginItemManager: loginItemManager
        )
        self.manager = mgr

        let controller = MenuBarController(manager: mgr)
        controller.onOpenPreferences = { [weak self] in
            self?.openPreferencesWindow()
        }
        self.menuBarController = controller

        mgr.onStateChanged = { [weak controller] state in
            controller?.update(with: state)
        }

        let isLoginItem = Self.detectIsSystemLoginLaunch()

        Task {
            // Respect requirement: do not prompt for notification permissions on system startup or launch;
            // only prompt when user connects their first account.
            await mgr.start(isSystemLoginStartup: isLoginItem)
        }
    }

    public func openPreferencesWindow() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = PreferencesViewModel(manager: manager)
        let contentView = PreferencesView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GmailPing 偏好设置"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false

        self.preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        manager?.stop()
    }
}
