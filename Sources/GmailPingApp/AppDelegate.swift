import AppKit
import SwiftUI
import Sparkle
import GmailPingCore

public final class AppDelegate: NSObject, NSApplicationDelegate, SPUStandardUserDriverDelegate, @unchecked Sendable {
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

        notificationService.setNotificationClickHandler { [weak self, weak mgr] accountId, _ in
            Task { @MainActor in
                if (try? await accountStorage.isAccountActive(accountId: accountId)) == true {
                    await mgr?.openInbox(for: accountId)
                } else {
                    self?.openPreferencesWindow()
                }
            }
        }

        // Plain SwiftPM executables and development bundles have no release feed.
        let updater = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil ? nil :
            SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        let controller = MenuBarController(manager: mgr, updater: updater)
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

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                          forUpdate update: SUAppcastItem,
                                                          state: SPUUserUpdateState) {
        menuBarController?.availableVersion = update.displayVersionString
    }

    public func standardUserDriverWillFinishUpdateSession() {
        menuBarController?.availableVersion = nil
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
