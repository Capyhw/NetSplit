// Version 版本比较的测试。不引入 SPM，用 swift 解释器模式跑。
//
// 跑法：
//     cat macos/Sources/Version.swift macos/Tests/version_test.swift | swift -
//
// 注意：设计文档里写的 `swift macos/Tests/version_test.swift macos/Sources/Version.swift`
// 跑不通 —— swift 解释器只把第一个文件当脚本，后面的文件会被当成脚本参数，
// 不会一起编译（报 cannot find 'Version' in scope）。所以改成 cat 拼成一个脚本喂给 stdin。
//
// 退出码非零表示失败。

import Foundation

var failures = 0
var checks = 0

func expect(_ actual: Bool, _ expected: Bool, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL \(label): got \(actual), want \(expected)")
    }
}

func expectNewer(_ latest: String, _ current: String, _ expected: Bool) {
    expect(Version.isNewer(latest, than: current), expected, "isNewer(\"\(latest)\", \"\(current)\")")
}

func expectEqual(_ actual: String, _ expected: String, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL \(label): got \"\(actual)\", want \"\(expected)\"")
    }
}

func expectParse(_ raw: String, _ expected: [Int]) {
    checks += 1
    let actual = Version.parse(raw)
    if actual != expected {
        failures += 1
        print("FAIL parse(\"\(raw)\"): got \(actual), want \(expected)")
    }
}

// MARK: - 设计文档行为表

expectNewer("0.4.0", "0.3.0", true)
expectNewer("v0.4.0", "0.3.0", true)
expectNewer("0.3", "0.3.0", false)
expectNewer("0.3.0", "0.3", false)
expectNewer("10.0", "9.9", true)
expectNewer("0.4.0-beta", "0.3.0", true)
expectNewer("0.4.0-beta", "0.4.0", false)
expectNewer("0.3.0", "0.3.0", false)

// MARK: - 补位：段数不等时短的一方按 0 补

expectNewer("1.0.0", "1.0.0.0", false)
expectNewer("1.0.0.0", "1.0.0", false)
expectNewer("1.0.0.1", "1.0.0", true)

// MARK: - 逐段数值比较，不是字符串比较

expectNewer("0.10.0", "0.9.0", true)
expectNewer("0.9.0", "0.10.0", false)
expectNewer("2.0.0", "10.0.0", false)

// MARK: - 前导 v / V

expectNewer("V0.4.0", "0.3.0", true)
expectNewer("v0.3.0", "0.3.0", false)

// MARK: - 预发布后缀被剥掉，不参与比较

expectNewer("0.4.0-rc.1", "0.4.0", false)
expectNewer("v0.5.0-beta", "0.4.0", true)
expectNewer("0.4.0-beta.1", "0.3.0", true)

// MARK: - 非法输入不崩溃

expectNewer("", "", false)
expectNewer("", "0.3.0", false)
expectNewer("abc", "abc", false)
expectNewer("abc", "0.3.0", false)
expectNewer("0.3.0", "abc", true)   // "abc" 解析成 0.0.0
expectNewer("...", "0.0.0", false)
expectNewer("v", "", false)
expectNewer("-", "", false)

// MARK: - parse

expectParse("0.4.0", [0, 4, 0])
expectParse("v0.4.0-beta", [0, 4, 0])
expectParse("1.2.3.4", [1, 2, 3, 4])
expectParse("abc", [0])
expectParse("", [0])
expectParse("10.0", [10, 0])

// MARK: - normalize

expectEqual(Version.normalize("0.4.0"), "0.4.0", "normalize(\"0.4.0\")")
expectEqual(Version.normalize("v0.4.0"), "0.4.0", "normalize(\"v0.4.0\")")
expectEqual(Version.normalize("V1.2.3"), "1.2.3", "normalize(\"V1.2.3\")")
expectEqual(Version.normalize("0.4.0-beta"), "0.4.0", "normalize(\"0.4.0-beta\")")
expectEqual(Version.normalize("0.4.0-beta.1"), "0.4.0", "normalize(\"0.4.0-beta.1\")")
expectEqual(Version.normalize("v"), "", "normalize(\"v\")")

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
