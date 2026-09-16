import Darwin
import Foundation
import Network

enum SplitError: LocalizedError {
    case missingEthernet
    case missingWiFi
    case ethernetDown(String)
    case wifiDown(String)
    case noEthernetGateway
    case noWiFiGateway
    case commandFailed(String, Int32, String)
    case privileged(String)
    case cancelled
    case gitConfigEmpty
    case gitConfigInvalid

    var errorDescription: String? {
        switch self {
        case .missingEthernet: "找不到网线网卡"
        case .missingWiFi: "找不到 Wi-Fi 网卡"
        case .ethernetDown(let name): "网线 \(name) 没有 IP，确认已插网线"
        case .wifiDown(let name): "Wi-Fi \(name) 没有 IP"
        case .noEthernetGateway: "读不到网线网关"
        case .noWiFiGateway: "读不到 Wi-Fi 网关"
        case .commandFailed(let cmd, let code, let err):
            "命令失败 (\(code)): \(cmd)\(err.isEmpty ? "" : "\n\(err)")"
        case .privileged(let msg): msg
        case .cancelled: "已取消授权"
        case .gitConfigEmpty: "gitconfig 里没有 http.proxy"
        case .gitConfigInvalid: "gitconfig 里的 proxy 无法解析"
        }
    }
}

struct GitProxyImport: Sendable {
    var proxyHost: String
    var proxyPort: Int
    var probeHost: String?
}

enum SplitMode: String, Sendable {
    case split
    case ethernetFirst
    case unknown
}

struct InterfaceInfo: Sendable, Equatable {
    var service: String
    var device: String
    var ip: String?
    var gateway: String?
}

struct NetworkSnapshot: Sendable {
    var mode: SplitMode
    var ethernet: InterfaceInfo?
    var wifi: InterfaceInfo?
    var defaultIface: String?
    var lanProxyIface: String?
    var lanProxyReachable: Bool
    var gitlabIP: String?
    var gitlabViaEthernet: Bool
    var services: [(name: String, device: String)]

    static let empty = NetworkSnapshot(
        mode: .unknown,
        ethernet: nil,
        wifi: nil,
        defaultIface: nil,
        lanProxyIface: nil,
        lanProxyReachable: false,
        gitlabIP: nil,
        gitlabViaEthernet: false,
        services: []
    )
}

enum SplitEngine {
    static let ethernetServiceDefault = "USB 10/100/1G/2.5G LAN"
    static let wifiServiceDefault = "Wi-Fi"
    static let legacyNets = ["10.222.0.0/16", "172.16.0.0/12"]

    static var stateDir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("net-split")
    }

    static var stateFile: URL { stateDir.appendingPathComponent("state") }

    static func snapshot(_ settings: SplitSettings = .load()) -> NetworkSnapshot {
        let services = serviceOrder()
        let names = listServices()
        let ethName = detectEthernet(in: names, override: settings.ethernetService)
        let wifiName = detectWiFi(in: names, override: settings.wifiService)
        let ethDev = device(for: ethName)
        let wifiDev = device(for: wifiName)

        let ethernet: InterfaceInfo? = ethDev.map {
            InterfaceInfo(
                service: ethName,
                device: $0,
                ip: ipAddress(for: $0),
                gateway: gateway(device: $0, service: ethName)
            )
        }
        let wifi: InterfaceInfo? = wifiDev.map {
            InterfaceInfo(
                service: wifiName,
                device: $0,
                ip: ipAddress(for: $0),
                gateway: gateway(device: $0, service: wifiName)
            )
        }

        let proxyHost = settings.proxyHost
        let def = routeInterface(to: "1.1.1.1")
        let lanIf = proxyHost.isEmpty ? nil : routeInterface(to: proxyHost)
        let reachable = !proxyHost.isEmpty
            && settings.proxyPort > 0
            && tcpOpen(host: proxyHost, port: settings.proxyPortValue, timeout: 1.5)

        let gitlab = settings.probeHost.isEmpty ? nil : resolveIPv4(settings.probeHost)
        let gitlabViaEth: Bool
        if let gitlab, let ethDev {
            gitlabViaEth = tcpOpen(host: gitlab, port: 443, timeout: 2, bindDevice: ethDev)
                || tcpOpen(host: gitlab, port: 80, timeout: 2, bindDevice: ethDev)
        } else {
            gitlabViaEth = false
        }

        let mode: SplitMode
        if let wifiDev, ethDev != nil, def == wifiDev {
            mode = .split
        } else if let ethDev, def == ethDev {
            mode = .ethernetFirst
        } else {
            mode = .unknown
        }

        return NetworkSnapshot(
            mode: mode,
            ethernet: ethernet,
            wifi: wifi,
            defaultIface: def,
            lanProxyIface: lanIf,
            lanProxyReachable: reachable,
            gitlabIP: gitlab,
            gitlabViaEthernet: gitlabViaEth,
            services: services
        )
    }

    static func enableSplit(_ settings: SplitSettings = .load()) throws {
        let names = listServices()
        let ethName = detectEthernet(in: names, override: settings.ethernetService)
        let wifiName = detectWiFi(in: names, override: settings.wifiService)
        guard let ethDev = device(for: ethName) else { throw SplitError.missingEthernet }
        guard let wifiDev = device(for: wifiName) else { throw SplitError.missingWiFi }
        guard ipAddress(for: ethDev) != nil else { throw SplitError.ethernetDown(ethName) }
        guard ipAddress(for: wifiDev) != nil else { throw SplitError.wifiDown(wifiName) }
        guard let ethGw = gateway(device: ethDev, service: ethName), !ethGw.isEmpty else {
            throw SplitError.noEthernetGateway
        }
        guard let wifiGw = gateway(device: wifiDev, service: wifiName), !wifiGw.isEmpty else {
            throw SplitError.noWiFiGateway
        }
        _ = wifiGw

        let prev = loadState()?.previousOrder ?? names
        let alreadySplit = loadState()?.mode == "split"
        let keepPrev = alreadySplit ? prev : names

        let ordered = reorder(puttingFirst: wifiName, in: names)
        var commands: [String] = [
            "/usr/sbin/networksetup -ordernetworkservices " + ordered.map(shQuote).joined(separator: " ")
        ]
        var gitlabIPs: [String] = []
        if !settings.usesProxy, !settings.probeHost.isEmpty {
            gitlabIPs = resolveIPv4All(settings.probeHost)
            for ip in gitlabIPs {
                commands.append("/sbin/route -n add -host \(shQuote(ip)) \(shQuote(ethGw)) >/dev/null 2>&1 || true")
            }
        }
        commands.append(contentsOf: legacyDeleteCommands())
        try Privileged.run(["/bin/bash", "-lc", commands.joined(separator: "; ")])
        saveState(mode: "split", previousOrder: keepPrev, ethernetGateway: ethGw, gitlabIPs: gitlabIPs)
    }

    static func disableSplit(_ settings: SplitSettings = .load()) throws {
        let names = listServices()
        let ethName = detectEthernet(in: names, override: settings.ethernetService)
        let state = loadState()
        var commands: [String] = legacyDeleteCommands()
        for ip in state?.gitlabIPs ?? [] {
            commands.append("/sbin/route -n delete -host \(shQuote(ip)) >/dev/null 2>&1 || true")
        }
        if let prev = state?.previousOrder, !prev.isEmpty {
            let existing = Set(names)
            let restored = prev.filter { existing.contains($0) }
            let missing = names.filter { !restored.contains($0) }
            commands.insert(
                "/usr/sbin/networksetup -ordernetworkservices "
                    + (restored + missing).map(shQuote).joined(separator: " "),
                at: 0
            )
            try Privileged.run(["/bin/bash", "-lc", commands.joined(separator: "; ")])
            saveState(mode: "off", previousOrder: prev, ethernetGateway: state?.ethernetGateway ?? "", gitlabIPs: [])
        } else {
            let ordered = reorder(puttingFirst: ethName, in: names)
            commands.insert(
                "/usr/sbin/networksetup -ordernetworkservices " + ordered.map(shQuote).joined(separator: " "),
                at: 0
            )
            try Privileged.run(["/bin/bash", "-lc", commands.joined(separator: "; ")])
            saveState(mode: "off", previousOrder: names, ethernetGateway: state?.ethernetGateway ?? "", gitlabIPs: [])
        }
    }

    // MARK: - Discovery

    static func listServices() -> [String] {
        let raw = run("/usr/sbin/networksetup", ["-listallnetworkservices"], allowFailure: true)
        return raw.split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { line -> String in
                var s = String(line)
                if s.hasPrefix("*") {
                    s.removeFirst()
                    s = s.trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .filter { !$0.isEmpty }
    }

    static func serviceOrder() -> [(name: String, device: String)] {
        let raw = run("/usr/sbin/networksetup", ["-listnetworkserviceorder"], allowFailure: true)
        var result: [(String, String)] = []
        var pendingName: String?
        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // "(Hardware Port: Wi-Fi, Device: en0)" 也以 ( 开头，必须先于服务名匹配。
            if trimmed.contains("Hardware Port:"), let deviceRange = trimmed.range(of: "Device: ") {
                let device = trimmed[deviceRange.upperBound...].prefix { $0 != ")" }
                    .trimmingCharacters(in: .whitespaces)
                if let name = pendingName, !device.isEmpty {
                    result.append((name, String(device)))
                    pendingName = nil
                }
            } else if trimmed.hasPrefix("("), trimmed.dropFirst().first?.isNumber == true,
                      let close = trimmed.firstIndex(of: ")") {
                let name = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { pendingName = name }
            }
        }
        if result.isEmpty {
            result = hardwarePortMap()
        }
        return result
    }

    static func hardwarePortMap() -> [(name: String, device: String)] {
        let raw = run("/usr/sbin/networksetup", ["-listallhardwareports"], allowFailure: true)
        var result: [(String, String)] = []
        var pendingName: String?
        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Hardware Port: ") {
                pendingName = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let name = pendingName {
                result.append((name, String(line.dropFirst("Device: ".count))))
                pendingName = nil
            }
        }
        return result
    }

    static func detectEthernet(in services: [String], override: String = "") -> String {
        if !override.isEmpty, services.contains(override) { return override }
        if let env = ProcessInfo.processInfo.environment["ETH_SERVICE"], !env.isEmpty {
            return env
        }
        if services.contains(ethernetServiceDefault) { return ethernetServiceDefault }
        return services.first { name in
            name.localizedCaseInsensitiveContains("LAN")
                || name.localizedCaseInsensitiveContains("Ethernet")
                || name.contains("以太网")
        } ?? ethernetServiceDefault
    }

    static func detectWiFi(in services: [String], override: String = "") -> String {
        if !override.isEmpty, services.contains(override) { return override }
        if let env = ProcessInfo.processInfo.environment["WIFI_SERVICE"], !env.isEmpty {
            return env
        }
        return services.first { name in
            name == wifiServiceDefault
                || name == "WiFi"
                || name.contains("无线局域网")
        } ?? wifiServiceDefault
    }

    static func device(for service: String) -> String? {
        serviceOrder().first(where: { $0.name == service })?.device
    }

    static func ipAddress(for device: String) -> String? {
        let out = run("/usr/sbin/ipconfig", ["getifaddr", device], allowFailure: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    static func gateway(device: String, service: String) -> String? {
        let dhcp = run("/usr/sbin/ipconfig", ["getoption", device, "router"], allowFailure: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !dhcp.isEmpty { return dhcp }

        let info = run("/usr/sbin/networksetup", ["-getinfo", service], allowFailure: true)
        for line in info.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Router: ") {
                let value = String(line.dropFirst("Router: ".count))
                if !value.isEmpty, value != "none" { return value }
            }
        }

        let table = run("/usr/sbin/netstat", ["-rn", "-f", "inet"], allowFailure: true)
        for line in table.split(whereSeparator: \.isNewline).map(String.init) {
            let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if cols.count >= 4, cols[0] == "default", cols.last == device {
                return cols[1]
            }
        }
        return nil
    }

    static func routeInterface(to host: String) -> String? {
        let out = run("/sbin/route", ["-n", "get", host], allowFailure: true)
        for line in out.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func resolveIPv4(_ host: String) -> String? {
        resolveIPv4All(host).first
    }

    static func resolveIPv4All(_ host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var ips: [String] = []
        var cursor = result
        while let info = cursor?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.ai_addr,
                info.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let ip = String(cString: buffer)
                if !ip.isEmpty, !ips.contains(ip) { ips.append(ip) }
            }
            cursor = info.ai_next
        }
        return ips
    }

    static func tcpOpen(host: String, port: UInt16, timeout: TimeInterval, bindDevice: String? = nil) -> Bool {
        let ip: String
        if host.contains(where: { $0 == "." }) && host.allSatisfy({ $0.isNumber || $0 == "." }) {
            ip = host
        } else {
            guard let resolved = resolveIPv4(host) else { return false }
            ip = resolved
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        if let bindDevice {
            var idx = if_nametoindex(bindDevice)
            guard idx != 0 else { return false }
            let bound = setsockopt(
                fd,
                IPPROTO_IP,
                IP_BOUND_IF,
                &idx,
                socklen_t(MemoryLayout<UInt32>.size)
            )
            guard bound == 0 else { return false }
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        let connecting = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connecting == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, Int32(timeout * 1000))
        guard pr > 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }

    // MARK: - Mutate

    static func reorder(puttingFirst first: String, in services: [String]) -> [String] {
        [first] + services.filter { $0 != first }
    }

    static func applyServiceOrder(_ services: [String]) throws {
        guard !services.isEmpty else { return }
        try Privileged.run(["/usr/sbin/networksetup", "-ordernetworkservices"] + services)
    }

    static func legacyDeleteCommands() -> [String] {
        legacyNets.compactMap { net in
            guard routeExists(net) else { return nil }
            return "/sbin/route -n delete -net \(shQuote(net)) >/dev/null 2>&1 || true"
        }
    }

    static func routeExists(_ net: String) -> Bool {
        let addr = net.split(separator: "/").first.map(String.init) ?? net
        let out = run("/sbin/route", ["-n", "get", addr], allowFailure: true)
        for line in out.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("destination:") {
                let dest = trimmed.replacingOccurrences(of: "destination:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return dest != "default" && !dest.isEmpty
            }
        }
        return false
    }

    // MARK: - State

    struct SavedState {
        var mode: String
        var previousOrder: [String]
        var ethernetGateway: String
        var gitlabIPs: [String]
    }

    static func loadState() -> SavedState? {
        guard let raw = try? String(contentsOf: stateFile, encoding: .utf8) else { return nil }
        var mode = ""
        var prev = ""
        var gw = ""
        var ips: [String] = []
        for line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("MODE=") { mode = String(line.dropFirst(5)) }
            if line.hasPrefix("PREV_ORDER=") { prev = String(line.dropFirst(11)) }
            if line.hasPrefix("ETH_GW=") { gw = String(line.dropFirst(7)) }
            if line.hasPrefix("GITLAB_IPS=") {
                ips = String(line.dropFirst(11)).split(separator: ",").map(String.init).filter { !$0.isEmpty }
            }
        }
        let order = prev.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return SavedState(mode: mode, previousOrder: order, ethernetGateway: gw, gitlabIPs: ips)
    }

    static func saveState(mode: String, previousOrder: [String], ethernetGateway: String, gitlabIPs: [String] = []) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let body = """
        MODE=\(mode)
        PREV_ORDER=\(previousOrder.joined(separator: ","))
        ETH_GW=\(ethernetGateway)
        GITLAB_IPS=\(gitlabIPs.joined(separator: ","))
        SAVED_AT=\(ISO8601DateFormatter().string(from: Date()))
        """
        try? body.write(to: stateFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Process

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String], allowFailure: Bool = false) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return ""
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !allowFailure, proc.terminationStatus != 0 {
            return stdout
        }
        return stdout
    }

    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func gitBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }

    /// 读取 gitconfig 里的 HTTP 代理。优先 per-url（http.<url>.proxy），否则 http.proxy / https.proxy。
    static func readGitProxy() throws -> GitProxyImport {
        let git = gitBinary()
        let output = run(git, ["config", "--global", "--get-regexp", #"http\..*proxy"#], allowFailure: true)
            + "\n"
            + run(git, ["config", "--global", "--get-regexp", #"https\..*proxy"#], allowFailure: true)
        let lines = output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw SplitError.gitConfigEmpty }

        var ranked: [(score: Int, item: GitProxyImport)] = []
        for line in lines {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            let value = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            guard let parsed = parseGitProxy(key: key, value: value) else { continue }
            let score = parsed.probeHost == nil ? 0 : 2
            ranked.append((score, parsed))
        }
        guard let best = ranked.max(by: { $0.score < $1.score })?.item else {
            throw SplitError.gitConfigInvalid
        }
        return best
    }

    static func parseGitProxy(key: String, value: String) -> GitProxyImport? {
        guard let proxy = parseProxyURL(value) else { return nil }
        var probe: String?
        let lower = key.lowercased()
        if let range = lower.range(of: "://") {
            let afterScheme = String(key[range.upperBound...])
            let hostPart = afterScheme.split(separator: "/").first.map(String.init) ?? ""
            let host = hostPart.split(separator: ":").first.map(String.init) ?? ""
            if !host.isEmpty, host != proxy.host {
                probe = host
            }
        }
        return GitProxyImport(proxyHost: proxy.host, proxyPort: proxy.port, probeHost: probe)
    }

    static func parseProxyURL(_ raw: String) -> (host: String, port: Int)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "http://\(text)"
        }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        let port = url.port ?? 80
        return (host, port)
    }
}

enum Privileged {
    static func run(_ arguments: [String]) throws {
        let command = arguments.map(SplitEngine.shQuote).joined(separator: " ")
        let source = "do shell script \(appleString(command)) with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw SplitError.privileged("无法创建授权脚本")
        }
        script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { throw SplitError.cancelled }
            let msg = (error[NSAppleScript.errorMessage] as? String) ?? "需要管理员权限"
            throw SplitError.privileged(msg)
        }
    }

    private static func appleString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
