import AppKit
import Sparkle
import GmailPingCore

public final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let updater: SPUStandardUpdaterController?
    private let manager: GmailPingManager
    private var currentState: MenuBarDisplayState?
    var availableVersion: String? {
        didSet { updateTooltip() }
    }
    public var onOpenPreferences: (() -> Void)?

    public init(manager: GmailPingManager, updater: SPUStandardUpdaterController? = nil) {
        self.updater = updater
        self.manager = manager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        setupStatusButton()
    }

    private func setupStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.makeEnvelopeIcon()
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    public func update(with state: MenuBarDisplayState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            self.currentState = state
            button.title = state.title
            self.updateTooltip()
            button.setAccessibilityLabel(state.accessibilityDescription)
        }
    }

    private func updateTooltip() {
        statusItem.button?.toolTip = [currentState?.tooltip, availableVersion.map { "可更新至 GmailPing \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApplication.shared.currentEvent else { return }

        let isRightClick = event.type == .rightMouseUp || event.modifierFlags.contains(.control)

        if isRightClick {
            showMenu(buildMenu(), from: sender)
            return
        }

        switch currentState?.primaryClickAction ?? .openPreferences {
        case .openPreferences:
            onOpenPreferences?()
        case .openInbox(let accountId):
            Task { await manager.openInbox(for: accountId) }
        case .chooseAccount(let accounts):
            let menu = NSMenu()
            for item in accounts {
                let row = menu.addItem(withTitle: "\(item.displayTitle) · \(item.unreadString)",
                                       action: #selector(openAccountInboxClicked(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = item.account.id
            }
            showMenu(menu, from: sender)
        }
    }

    private func showMenu(_ menu: NSMenu, from button: NSStatusBarButton) {
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard let state = currentState, state.hasAnyAccounts else {
            let emptyItem = NSMenuItem(title: "GmailPing (未添加账号)", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            menu.addItem(NSMenuItem.separator())

            let addItem = NSMenuItem(title: "添加 Google 账号...", action: #selector(openPreferencesClicked), keyEquivalent: "")
            addItem.target = self
            menu.addItem(addItem)
            menu.addItem(NSMenuItem.separator())

            addUpdateAndQuitItems(to: menu)
            return menu
        }

        // Header: Total
        let totalTitle: String
        if let total = state.totalUnread {
            totalTitle = "GmailPing · 合计 \(total) 封未读"
        } else {
            totalTitle = "GmailPing · 等待同步"
        }
        let headerItem = NSMenuItem(title: totalTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Accounts list
        for item in state.accountItems {
            let title = "\(item.displayTitle) · \(item.unreadString)"
            let accountMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")

            let subMenu = NSMenu()
            let openInboxItem = NSMenuItem(title: "打开收件箱", action: #selector(openAccountInboxClicked(_:)), keyEquivalent: "")
            openInboxItem.target = self
            openInboxItem.representedObject = item.account.id
            subMenu.addItem(openInboxItem)

            let checkItem = NSMenuItem(title: "立即检查", action: #selector(checkAccountClicked(_:)), keyEquivalent: "")
            checkItem.target = self
            checkItem.representedObject = item.account.id
            subMenu.addItem(checkItem)

            if !item.isDefault {
                let makeDefaultItem = NSMenuItem(title: "设为默认账号", action: #selector(setDefaultAccountClicked(_:)), keyEquivalent: "")
                makeDefaultItem.target = self
                makeDefaultItem.representedObject = item.account.id
                subMenu.addItem(makeDefaultItem)
            }

            let statusSubItem = NSMenuItem(title: item.lastSyncString, action: nil, keyEquivalent: "")
            statusSubItem.isEnabled = false
            subMenu.addItem(statusSubItem)

            accountMenuItem.submenu = subMenu
            menu.addItem(accountMenuItem)
        }

        menu.addItem(NSMenuItem.separator())

        let checkAllItem = NSMenuItem(title: "立即检查全部", action: #selector(checkAllClicked), keyEquivalent: "r")
        checkAllItem.target = self
        menu.addItem(checkAllItem)

        let openDefaultItem = NSMenuItem(title: "打开默认 Gmail", action: #selector(openDefaultClicked), keyEquivalent: "o")
        openDefaultItem.target = self
        menu.addItem(openDefaultItem)

        let prefItem = NSMenuItem(title: "偏好设置...", action: #selector(openPreferencesClicked), keyEquivalent: ",")
        prefItem.target = self
        menu.addItem(prefItem)

        menu.addItem(NSMenuItem.separator())

        addUpdateAndQuitItems(to: menu)
        return menu
    }

    private func addUpdateAndQuitItems(to menu: NSMenu) {
        if let updater {
            let title = availableVersion.map { "更新至 GmailPing \($0)…" } ?? "检查应用更新…"
            let check = menu.addItem(withTitle: title, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            check.isEnabled = updater.updater.canCheckForUpdates
            let automatic = menu.addItem(withTitle: "自动检查应用更新", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
            automatic.target = self
            automatic.state = updater.updater.automaticallyChecksForUpdates ? .on : .off
        }
        let quitItem = NSMenuItem(title: "退出 GmailPing", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Menu Actions

    @objc private func checkAllClicked() {
        Task {
            await manager.checkAllNow()
        }
    }

    @objc private func openDefaultClicked() {
        Task {
            await manager.openDefaultInbox()
        }
    }

    @objc private func openAccountInboxClicked(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? UUID else { return }
        Task {
            await manager.openInbox(for: accountId)
        }
    }

    @objc private func checkAccountClicked(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? UUID else { return }
        Task {
            await manager.checkAccountNow(accountId: accountId)
        }
    }

    @objc private func setDefaultAccountClicked(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? UUID else { return }
        Task {
            try? await manager.setDefaultAccount(accountId: accountId)
        }
    }

    @objc private func openPreferencesClicked() {
        onOpenPreferences?()
    }

    @objc private func toggleAutomaticUpdates() {
        updater?.updater.automaticallyChecksForUpdates.toggle()
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
