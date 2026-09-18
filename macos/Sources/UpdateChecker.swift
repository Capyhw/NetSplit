import Foundation

struct ReleaseInfo {
    /// 已剥掉 `v` 前缀，如 "0.4.0"
    let version: String
    /// html_url，浏览器打开用
    let url: URL
    /// release body，供 tooltip
    let notes: String
}

enum UpdateCheckResult {
    case upToDate
    case available(ReleaseInfo)
    case failed
}

enum UpdateChecker {
    static let repository = "Capyhw/NetSplit"

    private static let requestTimeout: TimeInterval = 10

    /// `/releases/latest` 已排除 draft 和 prerelease，只取用得到的字段。
    private struct Payload: Decodable {
        let tag_name: String?
        let html_url: String?
        let body: String?
    }

    /// Bundle.main 的 CFBundleShortVersionString。
    ///
    /// 未打包直接跑源码时为 nil —— 此时一律判失败，避免开发态把任何 release 都当成新版。
    static func currentVersion() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func latestRelease() async -> UpdateCheckResult {
        guard let current = currentVersion() else { return .failed }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return .failed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API 不带 User-Agent 会返回 403
        request.setValue("NetSplit/\(current)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard let tag = payload.tag_name, !tag.isEmpty,
                  let link = payload.html_url, let releaseURL = URL(string: link) else {
                return .failed
            }
            guard Version.isNewer(tag, than: current) else { return .upToDate }

            let display = Version.normalize(tag)
            return .available(ReleaseInfo(
                version: display.isEmpty ? tag : display,
                url: releaseURL,
                notes: payload.body ?? ""
            ))
        } catch {
            return .failed
        }
    }
}
