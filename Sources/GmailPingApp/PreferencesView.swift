import SwiftUI
import GmailPingCore

public final class PreferencesViewModel: ObservableObject {
    @Published public var preferences: AppPreferences
    @Published public var accounts: [Account] = []
    @Published public var snapshots: [UUID: AccountSnapshot] = [:]
    @Published public var defaultAccountId: UUID?
    @Published public var isAddingAccount: Bool = false
    @Published public var errorMessage: String?
    @Published public var loginItemStatus: LoginItemStatus = .notRegistered

    private let manager: GmailPingManager
    private let coordinator: OAuthFlowCoordinator

    public init(manager: GmailPingManager) {
        self.manager = manager
        self.preferences = manager.preferencesStorage.loadPreferences()
        self.loginItemStatus = manager.loginItemManager.status
        self.coordinator = OAuthFlowCoordinator(
            oauthClient: manager.oauthClient,
            gmailClient: manager.gmailClient,
            keychainStorage: manager.keychainStorage,
            accountStorage: manager.accountStorage,
            browserLauncher: manager.browserLauncher,
            syncEngine: manager.syncEngine
        )
        refresh()
    }

    public func refresh() {
        Task { @MainActor in
            let dir = (try? await manager.accountStorage.loadDirectory()) ?? AccountDirectory()
            self.accounts = dir.accounts.filter { !$0.isPendingCleanup }
            self.defaultAccountId = dir.defaultAccountId
            self.preferences = manager.preferencesStorage.loadPreferences()
            self.loginItemStatus = manager.loginItemManager.status

            var snaps: [UUID: AccountSnapshot] = [:]
            for acc in self.accounts {
                if let snap = try? await manager.accountStorage.loadSnapshot(for: acc.id) {
                    snaps[acc.id] = snap
                }
            }
            self.snapshots = snaps
        }
    }

    public func updatePreferences(_ newPrefs: AppPreferences) {
        self.preferences = newPrefs
        Task {
            await manager.updatePreferences(newPrefs)
            await MainActor.run { self.refresh() }
        }
    }

    public func setDefault(accountId: UUID) {
        Task {
            try? await manager.setDefaultAccount(accountId: accountId)
            await MainActor.run { self.refresh() }
        }
    }

    public func removeAccount(accountId: UUID) {
        Task {
            try? await manager.removeAccount(accountId: accountId)
            await MainActor.run { self.refresh() }
        }
    }

    public func cancelAddingAccount() {
        Task { await coordinator.cancel() }
        isAddingAccount = false
    }

    public func addAccount() {
        isAddingAccount = true
        errorMessage = nil
        Task {
            // "首个账号由用户连接后说明通知用途并调用系统授权。"
            if self.accounts.isEmpty {
                _ = await manager.notificationService.requestAuthorization()
            }

            do {
                _ = try await coordinator.addAccountFlow()
                await MainActor.run {
                    self.isAddingAccount = false
                    self.refresh()
                }
                await manager.notifyStateChanged()
            } catch {
                await MainActor.run {
                    self.isAddingAccount = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func reauthAccount(account: Account) {
        isAddingAccount = true
        errorMessage = nil
        Task {
            do {
                try await coordinator.reauthAccountFlow(account: account)
                await MainActor.run {
                    self.isAddingAccount = false
                    self.refresh()
                }
                await manager.notifyStateChanged()
            } catch {
                await MainActor.run {
                    self.isAddingAccount = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

public struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @State private var accountToRemove: Account?
    @State private var showingRemoveAlert = false

    public init(viewModel: PreferencesViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            accountsTab
                .tabItem {
                    Label("账号", systemImage: "person.2")
                }
        }
        .frame(width: 540, height: 440)
        .padding()
        .alert("确认移除账号", isPresented: $showingRemoveAlert, presenting: accountToRemove) { acc in
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                viewModel.removeAccount(accountId: acc.id)
            }
        } message: { acc in
            Text("确定要移除 \(acc.email) 吗？这会清除本地凭据和所有该邮箱的未读状态与通知。")
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("系统启动") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("登录时自动启动 GmailPing", isOn: Binding(
                        get: { viewModel.preferences.launchAtLogin },
                        set: { val in
                            var p = viewModel.preferences
                            p.launchAtLogin = val
                            viewModel.updatePreferences(p)
                        }
                    ))

                    HStack(spacing: 4) {
                        Text("系统登录项状态:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(viewModel.loginItemStatus.rawValue)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(viewModel.loginItemStatus == .enabled ? .primary : .orange)

                        Spacer()

                        Button("打开系统设置...") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            Section("检查间隔") {
                Picker("自动检查新邮件", selection: Binding(
                    get: { viewModel.preferences.checkInterval },
                    set: { val in
                        var p = viewModel.preferences
                        p.checkInterval = val
                        viewModel.updatePreferences(p)
                    }
                )) {
                    ForEach(CheckInterval.allCases, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
            }

            Section("菜单栏") {
                Toggle("在菜单栏显示未读数量", isOn: Binding(
                    get: { viewModel.preferences.showUnreadCount },
                    set: { val in
                        var p = viewModel.preferences
                        p.showUnreadCount = val
                        viewModel.updatePreferences(p)
                    }
                ))

                Toggle("未读为零时隐藏数字", isOn: Binding(
                    get: { viewModel.preferences.hideCountWhenZero },
                    set: { val in
                        var p = viewModel.preferences
                        p.hideCountWhenZero = val
                        viewModel.updatePreferences(p)
                    }
                ))
                .disabled(!viewModel.preferences.showUnreadCount)
            }

            Section("通知与声音") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("收到新邮件时发送系统通知", isOn: Binding(
                        get: { viewModel.preferences.systemNotificationsEnabled },
                        set: { val in
                            var p = viewModel.preferences
                            p.systemNotificationsEnabled = val
                            viewModel.updatePreferences(p)
                        }
                    ))

                    Toggle("播放通知提示音", isOn: Binding(
                        get: { viewModel.preferences.notificationSoundEnabled },
                        set: { val in
                            var p = viewModel.preferences
                            p.notificationSoundEnabled = val
                            viewModel.updatePreferences(p)
                        }
                    ))
                    .disabled(!viewModel.preferences.systemNotificationsEnabled)

                    Toggle("系统登录时提醒已有未读", isOn: Binding(
                        get: { viewModel.preferences.notifyExistingUnreadOnSystemLogin },
                        set: { val in
                            var p = viewModel.preferences
                            p.notifyExistingUnreadOnSystemLogin = val
                            viewModel.updatePreferences(p)
                        }
                    ))

                    HStack {
                        Spacer()
                        Button("打开系统通知设置...") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Accounts Tab

    private var accountsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorMsg = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(errorMsg)
                        .font(.callout)
                        .foregroundColor(.primary)
                    Spacer()
                    Button("关闭") {
                        viewModel.errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(8)
            }

            if viewModel.accounts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("尚未添加任何 Google 账号")
                        .font(.headline)
                    Text("添加后即可在菜单栏实时汇总未读邮件")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.accounts) { account in
                        accountRow(account: account)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            HStack {
                Button(action: {
                    viewModel.addAccount()
                }) {
                    HStack {
                        Image(systemName: "plus")
                        Text("添加 Google 账号...")
                    }
                }
                .disabled(viewModel.isAddingAccount)

                if viewModel.isAddingAccount {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("正在等待浏览器授权...")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("取消") {
                        viewModel.cancelAddingAccount()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()
            }
        }
    }

    private func accountRow(account: Account) -> some View {
        let isDefault = account.id == viewModel.defaultAccountId
        let snapshot = viewModel.snapshots[account.id]

        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.email)
                        .font(.system(size: 14, weight: .medium))

                    if isDefault {
                        Text("默认")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }

                    if snapshot?.needsReauth == true {
                        Text("需要重新授权")
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.15))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 8) {
                    if let count = snapshot?.unreadCount {
                        Text("\(count) 封未读")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("等待同步")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("·")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(snapshot != nil ? AccountStatusItem(account: account, snapshot: snapshot, isDefault: isDefault).lastSyncString : "尚未同步")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !isDefault {
                Button("设为默认") {
                    viewModel.setDefault(accountId: account.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if snapshot?.needsReauth == true {
                Button("重新授权") {
                    viewModel.reauthAccount(account: account)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                accountToRemove = account
                showingRemoveAlert = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
