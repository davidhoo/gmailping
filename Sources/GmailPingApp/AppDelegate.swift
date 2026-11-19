import AppKit
import SwiftUI
import GmailPingCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: GmailPingManager!
    private var menuBarController: MenuBarController!
    private var preferencesWindow: NSWindow?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Set as accessory application (no Dock icon)
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

        // Handle notification click: open inbox for that account
        notificationService.setNotificationClickHandler { [weak browserLauncher] accountId, email in
            browserLauncher?.openInbox(for: email)
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

        let isLoginItem = CommandLine.arguments.contains("--login-item")

        Task {
            // Request notification permission on first launch
            _ = await notificationService.requestAuthorization()
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
