import Foundation

/// 版本号比较。
///
/// 纯函数，不依赖 SwiftUI，以便被 `macos/Tests/version_test.swift` 单独编译运行。
enum Version {
    /// 剥掉前导 `v` / `V`，再剥掉第一个 `-` 及其之后的预发布后缀。
    ///
    ///     "v0.4.0-beta.1" -> "0.4.0"
    static func normalize(_ raw: String) -> String {
        var text = raw
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let dash = text.firstIndex(of: "-") {
            text = String(text[text.startIndex..<dash])
        }
        return text
    }

    /// 按 `.` 切分并逐段转 `Int`，无法解析的段按 `0` 处理。
    static func parse(_ raw: String) -> [Int] {
        normalize(raw)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }

    /// `latest` 是否比 `current` 新。段数不等时短的一方按 `0` 补位。
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let left = parse(latest)
        let right = parse(current)
        for index in 0..<max(left.count, right.count) {
            let new = index < left.count ? left[index] : 0
            let old = index < right.count ? right[index] : 0
            if new != old { return new > old }
        }
        return false
    }
}
