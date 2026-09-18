import AppKit
import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject private var model: SplitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.showSettings {
                settingsCard
            } else {
                laneCard
                actions
                probes
            }
            if let error = model.errorMessage {
                errorBanner(error)
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(PanelWindowFitter())
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if !model.busy, !model.showSettings { model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: model.menuSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(modeColor)
                .frame(width: 32, height: 32)
                .background(modeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.modeTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(model.modeSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: {
                if model.showSettings {
                    model.cancelSettings()
                } else {
                    model.openSettings()
                }
            }) {
                Image(systemName: model.showSettings ? "xmark.circle.fill" : "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(model.showSettings ? "关闭设置" : "设置")
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("局域网代理")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("IP 或主机名", text: model.binding(\.proxyHost))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospaced())
                Text(":")
                    .foregroundStyle(.secondary)
                TextField("端口", text: model.portTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospaced())
                    .frame(width: 64)
            }
            Text("留空则网线直连 GitLab，不经过局域网代理")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Text("GitLab 域名")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("用于探测网线是否能访问", text: model.binding(\.probeHost))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())

            Text("网卡（一般不用改）")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            servicePicker("网线", selection: model.binding(\.ethernetService))
            servicePicker("Wi-Fi", selection: model.binding(\.wifiService))

            HStack {
                Button("恢复默认") {
                    model.draft = .default
                }
                .controlSize(.small)
                Button("从 gitconfig 读取") {
                    model.importGitProxy()
                }
                .controlSize(.small)
                Spacer()
                Button("保存") { model.saveSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func servicePicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 40, alignment: .leading)
            Picker("", selection: selection) {
                Text("自动识别").tag("")
                ForEach(model.snapshot.services.map(\.name), id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private var laneCard: some View {
        VStack(spacing: 0) {
            LaneRow(
                title: "Wi-Fi",
                symbol: "wifi",
                info: model.snapshot.wifi,
                badge: model.snapshot.mode == .split ? "默认上网" : nil,
                accent: Color(red: 0.18, green: 0.62, blue: 0.55),
                active: model.snapshot.defaultIface == model.snapshot.wifi?.device
            )
            Divider().opacity(0.5)
            LaneRow(
                title: "网线",
                symbol: "cable.connector",
                info: model.snapshot.ethernet,
                badge: model.settings.usesProxy ? "局域网代理" : "直连 GitLab",
                accent: Color(red: 0.22, green: 0.45, blue: 0.86),
                active: model.settings.usesProxy
                    ? model.snapshot.lanProxyIface == model.snapshot.ethernet?.device
                    : model.snapshot.gitlabViaEthernet
            )
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if model.snapshot.mode == .split {
                Button(action: model.disableSplit) {
                    labelButton("恢复网线优先", systemImage: "cable.connector")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.busy)
            } else {
                Button(action: model.enableSplit) {
                    labelButton("开启分流", systemImage: "wifi")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.18, green: 0.62, blue: 0.55))
                .controlSize(.large)
                .disabled(model.busy || model.snapshot.wifi?.ip == nil || model.snapshot.ethernet?.ip == nil)
            }

            Text("切换服务顺序需要输入本机密码")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var probes: some View {
        VStack(spacing: 6) {
            ProbeRow(
                title: "默认出口",
                value: defaultRouteText,
                ok: model.snapshot.defaultIface != nil
            )
            if model.settings.usesProxy {
                ProbeRow(
                    title: "局域网代理",
                    value: lanProxyText,
                    ok: model.snapshot.lanProxyReachable
                        && (model.snapshot.ethernet?.device == nil
                            || model.snapshot.lanProxyIface == model.snapshot.ethernet?.device)
                )
            }
            if !model.settings.probeHost.isEmpty {
                ProbeRow(
                    title: "网线访问 GitLab",
                    value: gitlabProbeText,
                    ok: model.snapshot.gitlabViaEthernet
                )
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("登录时启动", isOn: launchAtLoginBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer(minLength: 4)
                Button("刷新") { model.refresh() }
                    .disabled(model.busy)
                updateButton
                Button("退出") { model.quit() }
            }
            if let message = model.updateMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .font(.system(size: 11))
    }

    @ViewBuilder
    private var updateButton: some View {
        if let update = model.availableUpdate {
            Button(action: model.openReleasePage) {
                Label("更新到 v\(update.version)", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .help(update.notes)
        } else {
            Button("检查更新") { model.checkForUpdates(manual: true) }
                .disabled(model.checkingUpdate)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { model.toggleLaunchAtLogin($0) }
        )
    }

    private var modeColor: Color {
        switch model.snapshot.mode {
        case .split: Color(red: 0.18, green: 0.62, blue: 0.55)
        case .ethernetFirst: Color(red: 0.22, green: 0.45, blue: 0.86)
        case .unknown: .secondary
        }
    }

    private var defaultRouteText: String {
        let iface = model.snapshot.defaultIface ?? "?"
        if iface == model.snapshot.wifi?.device { return "\(iface)  Wi-Fi" }
        if iface == model.snapshot.ethernet?.device { return "\(iface)  网线" }
        return iface
    }

    private var lanProxyText: String {
        let host = model.settings.proxyDisplay
        let via = model.snapshot.lanProxyIface ?? "?"
        if model.snapshot.lanProxyReachable {
            return "\(host)  \(via)"
        }
        return "\(host)  不通"
    }

    private var gitlabProbeText: String {
        guard let ip = model.snapshot.gitlabIP else { return "解析失败" }
        if model.snapshot.gitlabViaEthernet {
            return "\(ip)  通"
        }
        return "\(ip)  不通"
    }

    private func labelButton(_ title: String, systemImage: String) -> some View {
        HStack {
            if model.busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// MenuBarExtra 的面板窗口只涨不缩：设置页比主界面高，从设置页退回来之后窗口还是那么高，
/// 多出来的空间把内容垂直居中——面板上下边界于是"缩进去"，窗口的圆角、阴影落在内容之外。
/// 这里在每次布局之后把窗口高度对齐回内容的实际高度（上沿不动，面板始终贴着菜单栏），
/// 让面板跟着内容一起收放，而不是把高度写死。
private struct PanelWindowFitter: NSViewRepresentable {
    /// 面板内容的合理高度区间：万一量歪了（取到的不是承载 SwiftUI 的那一层），
    /// 宁可按老样子显示，也不要把面板裁掉或者撑成一大条。
    private static let plausibleHeight: ClosedRange<CGFloat> = 200...1200

    func makeNSView(context: Context) -> NSView {
        let view = FitterView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // 等这一轮布局落定，内容高度才是最终值。
        DispatchQueue.main.async { Self.fit(view) }
    }

    fileprivate static func fit(_ view: NSView) {
        guard let window = view.window, let content = window.contentView else { return }
        let height = contentHeight(in: content)
        guard plausibleHeight.contains(height), abs(window.frame.height - height) > 0.5 else { return }
        let top = window.frame.maxY
        var frame = window.frame
        frame.size.height = height
        frame.origin.y = top - height
        window.setFrame(frame, display: true)
        // 窗口是系统在管的，它可能隔一拍又按旧高度摆回来，所以再确认一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { fit(view) }
    }

    /// 承载 SwiftUI 的视图的理想高度就是内容高度。面板窗口的 contentView 是
    /// MenuBarExtraHostingView，它自己报不出来（返回 0），真正承载 SwiftUI 的那层在它里面，
    /// 所以往下找，取能报出高度的最大值。
    private static func contentHeight(in view: NSView) -> CGFloat {
        var height = isHosting(view) ? view.fittingSize.height : 0
        for sub in view.subviews {
            height = max(height, contentHeight(in: sub))
        }
        if height <= 1, !isHosting(view) { height = view.fittingSize.height }
        return height
    }

    private static func isHosting(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("Hosting")
    }
}

/// 面板每次打开都是把内容重新挂到窗口上，这时候窗口还留着上一轮的高度，也要对齐一次。
private final class FitterView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // 挂上去的那一刻内容还没布局完，量不到高度，隔一拍再确认一次。
        DispatchQueue.main.async { PanelWindowFitter.fit(self) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { PanelWindowFitter.fit(self) }
    }
}

private struct LaneRow: View {
    let title: String
    let symbol: String
    let info: InterfaceInfo?
    let badge: String?
    let accent: Color
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(accent)
                    }
                }
                Text(detail)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(info?.ip == nil ? Color.secondary.opacity(0.35) : (active ? accent : Color.secondary.opacity(0.45)))
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var detail: String {
        guard let info else { return "未连接" }
        let ip = info.ip ?? "无地址"
        return "\(info.device)  \(ip)"
    }
}

private struct ProbeRow: View {
    let title: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color(red: 0.18, green: 0.62, blue: 0.55) : Color.orange)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
