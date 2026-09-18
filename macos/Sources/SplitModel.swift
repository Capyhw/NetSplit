import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class SplitModel: ObservableObject {
    @Published var snapshot = NetworkSnapshot.empty
    @Published var settings = SplitSettings.load()
    @Published var draft = SplitSettings.load()
    @Published var showSettings = false
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var launchAtLogin = false
    @Published var lastRefresh: Date?
    @Published var checkingUpdate = false
    @Published var availableUpdate: ReleaseInfo?
    @Published var updateMessage: String?

    private var updateMessageToken = 0

    var menuSymbol: String {
        switch snapshot.mode {
        case .split: "wifi"
        case .ethernetFirst: "cable.connector"
        case .unknown: "network"
        }
    }

    var modeTitle: String {
        switch snapshot.mode {
        case .split: "分流中"
        case .ethernetFirst: "网线优先"
        case .unknown: "未识别"
        }
    }

    var modeSubtitle: String {
        switch snapshot.mode {
        case .split:
            settings.usesProxy ? "Wi-Fi 上网，内网走网线代理" : "Wi-Fi 上网，GitLab 走网线"
        case .ethernetFirst: "默认全部走网线"
        case .unknown: "插上网线并连上 Wi-Fi 后再看"
        }
    }

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refresh()
        checkForUpdates(manual: false)
    }

    func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        let current = settings
        let snap = await Task.detached(priority: .userInitiated) {
            SplitEngine.snapshot(current)
        }.value
        snapshot = snap
        lastRefresh = Date()
    }

    func enableSplit() {
        let current = settings
        runChange { try SplitEngine.enableSplit(current) }
    }

    func disableSplit() {
        let current = settings
        runChange { try SplitEngine.disableSplit(current) }
    }

    func openSettings() {
        draft = settings
        showSettings = true
    }

    func cancelSettings() {
        draft = settings
        showSettings = false
    }

    func importGitProxy() {
        errorMessage = nil
        do {
            let imported = try SplitEngine.readGitProxy()
            var next = draft
            next.proxyHost = imported.proxyHost
            next.proxyPort = imported.proxyPort
            if let probe = imported.probeHost, !probe.isEmpty {
                next.probeHost = probe
            }
            draft = next
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSettings() {
        let next = draft.normalized()
        if next.usesProxy, next.proxyPort < 1 {
            errorMessage = "填写了代理地址时，请同时填写端口"
            return
        }
        settings = next
        settings.save()
        showSettings = false
        errorMessage = nil
        refresh()
    }

    func binding<Value>(_ keyPath: WritableKeyPath<SplitSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { value in
                var next = self.draft
                next[keyPath: keyPath] = value
                self.draft = next
            }
        )
    }

    var portTextBinding: Binding<String> {
        Binding(
            get: { self.draft.proxyPort > 0 ? String(self.draft.proxyPort) : "" },
            set: { text in
                var next = self.draft
                let digits = text.filter(\.isNumber)
                next.proxyPort = digits.isEmpty ? 0 : (Int(digits) ?? 0)
                self.draft = next
            }
        )
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = "登录启动失败。把 App 放到「应用程序」后再试。\n\(error.localizedDescription)"
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 检查更新

    /// 启动时静默查一次；手动检查才回写 updateMessage。
    func checkForUpdates(manual: Bool) {
        if manual, checkingUpdate { return }
        checkingUpdate = true
        Task {
            let result = await UpdateChecker.latestRelease()
            checkingUpdate = false
            switch result {
            case .available(let info):
                availableUpdate = info
            case .upToDate:
                if manual { showUpdateMessage("已是最新") }
            case .failed:
                if manual { showUpdateMessage("检查更新失败") }
            }
        }
    }

    func openReleasePage() {
        guard let info = availableUpdate else { return }
        NSWorkspace.shared.open(info.url)
    }

    /// 3 秒后自动清空，用递增令牌保证只清掉自己写的那条。
    private func showUpdateMessage(_ text: String) {
        updateMessage = text
        updateMessageToken += 1
        let token = updateMessageToken
        Task {
            try? await Task.sleep(for: .seconds(3))
            if updateMessageToken == token { updateMessage = nil }
        }
    }

    private func runChange(_ work: @escaping () throws -> Void) {
        busy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try work()
                await refreshNow()
            } catch {
                errorMessage = error.localizedDescription
                await refreshNow()
            }
            busy = false
        }
    }
}
