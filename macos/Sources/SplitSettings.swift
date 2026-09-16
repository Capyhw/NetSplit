import Foundation

struct SplitSettings: Codable, Equatable, Sendable {
    var proxyHost: String
    var proxyPort: Int
    var probeHost: String
    var ethernetService: String
    var wifiService: String

    static let `default` = SplitSettings(
        proxyHost: "",
        proxyPort: 0,
        probeHost: "",
        ethernetService: "",
        wifiService: ""
    )

    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/net-split")
    }

    static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    var usesProxy: Bool {
        !proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var proxyPortValue: UInt16 {
        let clamped = min(max(proxyPort, 1), 65535)
        return UInt16(clamped)
    }

    var proxyDisplay: String {
        let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return "直连 GitLab" }
        if proxyPort < 1 { return host }
        return "\(host):\(proxyPortValue)"
    }

    func normalized() -> SplitSettings {
        var next = self
        next.proxyHost = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        next.probeHost = probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        next.ethernetService = ethernetService.trimmingCharacters(in: .whitespacesAndNewlines)
        next.wifiService = wifiService.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.proxyHost.isEmpty {
            next.proxyPort = 0
        } else if next.proxyPort < 1 || next.proxyPort > 65535 {
            next.proxyPort = 0
        }
        return next
    }

    static func load() -> SplitSettings {
        let url = configFile
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(SplitSettings.self, from: data) else {
            return .default
        }
        return loaded.normalized()
    }

    func save() {
        let value = normalized()
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: Self.configFile, options: .atomic)
    }
}
