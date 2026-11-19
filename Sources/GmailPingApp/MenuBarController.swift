import AppKit
import GmailPingCore

public final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let manager: GmailPingManager
    private var currentState: MenuBarDisplayState?
    public var onOpenPreferences: (() -> Void)?

    public init(manager: GmailPingManager) {
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
        self.currentState = state
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            button.title = state.title
            button.toolTip = state.tooltip
            button.setAccessibilityLabel(state.accessibilityDescription)
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApplication.shared.currentEvent else { return }

        let isRightClick = event.type == .rightMouseUp || event.modifierFlags.contains(.control)

        if isRightClick {
            let menu = buildMenu()
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click
            guard let state = currentState, state.hasAnyAccounts else {
                onOpenPreferences?()
                return
            }
            Task {
                await manager.openDefaultInbox()
            }
        }
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

            let quitItem = NSMenuItem(title: "退出 GmailPing", action: #selector(quitClicked), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
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

        let quitItem = NSMenuItem(title: "退出 GmailPing", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
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

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
