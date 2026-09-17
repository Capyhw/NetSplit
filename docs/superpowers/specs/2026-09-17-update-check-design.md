# 检查更新 / 下载更新（基于 GitHub Release）设计

日期：2026-09-17
状态：已确认，待实现

## 目标

NetSplit 菜单栏 app 能知道自己是不是最新版；有新版本时提示用户，并一键把用户送到 GitHub Release 页面下载。

**范围边界**：只做「检查 + 提示 + 跳转浏览器」。不下载、不安装。

## 背景

- 仓库 `Capyhw/NetSplit`，Releases 里挂 `网卡分流-<版本>.dmg` 和 `.pkg`（见 `.github/workflows/release.yml`）
- 版本号唯一来源是 `macos/Info.plist` 的 `CFBundleShortVersionString`（当前 `0.3.0`），tag 形如 `v0.3.0`
- 发布流程：改 Info.plist 版本 → 打 tag `v*` → 推 → Actions 自动编译并建 Release
- 构建体系是 `build.sh` 直接调 `swiftc`，**没有 SPM 工程、没有 Xcode 工程、零第三方依赖**。这个现状约束了方案选型
- App 未做 Apple 公证，`codesign --sign -` 仅 ad-hoc 签名

## 选型：GitHub REST API

`GET https://api.github.com/repos/Capyhw/NetSplit/releases/latest`

理由：

- `/releases/latest` 本身已排除 draft 和 prerelease，无需自行过滤
- 一次拿到 `tag_name`、`body`（更新说明）、`html_url`
- 公开仓库无需 token；未认证限额 60 次/小时/IP，本项目只在启动时查一次，绰绰有余
- 请求头必须带 `User-Agent`，否则 GitHub API 返回 403

被否决的替代方案：

| 方案 | 否决原因 |
|---|---|
| Sparkle 框架 | 引入外部依赖，与「零依赖 + 纯 swiftc 构建」现状冲突；需要 EdDSA 签名密钥、appcast 托管、XPC 服务，对本需求过重 |
| 解析 `github.com/.../releases/latest` 的 302 | 只能从 `Location` 里抠出 tag，拿不到更新说明 |
| 刮 Release 页 HTML | 依赖页面结构，最脆弱 |

## 组件设计

### 1. `macos/Sources/Version.swift`（新增）

纯函数，**不 import SwiftUI**，以便被测试脚本单独编译。

```swift
enum Version {
    static func parse(_ raw: String) -> [Int]
    static func isNewer(_ latest: String, than current: String) -> Bool
}
```

比较规则：

1. 剥掉前导 `v` / `V`
2. 剥掉第一个 `-` 及其之后的全部内容（预发布后缀不参与比较）
3. 按 `.` 切分，逐段转 `Int`；无法解析的段按 `0` 处理
4. 逐段比较，段数不等时短的一方按 `0` 补位

由此得到的行为：

| 表达式 | 结果 |
|---|---|
| `isNewer("0.4.0", "0.3.0")` | true |
| `isNewer("v0.4.0", "0.3.0")` | true |
| `isNewer("0.3", "0.3.0")` | false |
| `isNewer("0.3.0", "0.3")` | false |
| `isNewer("10.0", "9.9")` | true |
| `isNewer("0.4.0-beta", "0.3.0")` | true（剥后缀后 0.4.0 > 0.3.0） |
| `isNewer("0.4.0-beta", "0.4.0")` | false（后缀被剥掉，二者等值） |
| `isNewer("0.3.0", "0.3.0")` | false |

### 2. `macos/Sources/UpdateChecker.swift`（新增）

```swift
struct ReleaseInfo {
    let version: String   // 已剥掉 v 前缀，如 "0.4.0"
    let url: URL          // html_url，浏览器打开用
    let notes: String     // release body，供 tooltip
}

enum UpdateCheckResult {
    case upToDate
    case available(ReleaseInfo)
    case failed
}

enum UpdateChecker {
    static func currentVersion() -> String?   // Bundle.main 的 CFBundleShortVersionString
    static func latestRelease() async -> UpdateCheckResult
}
```

行为：

- `URLSession` shared，`timeoutIntervalForRequest` 10 秒
- 请求头 `Accept: application/vnd.github+json`、`User-Agent: NetSplit/<当前版本>`
- 只接受 HTTP 200；其余状态码、解码失败、超时、断网 → `.failed`
- `currentVersion()` 取不到（例如未打包直接跑源码）→ 直接 `.failed`，避免开发态把任何 release 都判成新版而误报
- 用 `Version.isNewer(tag, than: current)` 判定；不新则 `.upToDate`
- 解析响应只取需要的字段，用 `Codable` 且全部字段可选，缺 `html_url` 视为 `.failed`

### 3. `macos/Sources/SplitModel.swift`（修改）

新增：

```swift
@Published var checkingUpdate = false
@Published var availableUpdate: ReleaseInfo?   // nil = 无新版
@Published var updateMessage: String?          // 仅手动检查时出现，3 秒后自动清空
```

行为：

- `init()` 末尾发起一次 `checkForUpdates(manual: false)`，静默进行；失败或已是最新都不写 `updateMessage`，不打扰用户
- `manual: true` 时：`.upToDate` → `updateMessage = "已是最新"`；`.failed` → `updateMessage = "检查更新失败"`
- `updateMessage` 的 3 秒自动清空由 model 自己负责：写入后起一个 `Task`，`try? await Task.sleep(for: .seconds(3))` 后仅在消息未被新消息替换的情况下清空（用一个私有递增计数或私有时间戳做令牌）。UI 不需要知道时间戳
- `manual: true` 时若正在检查则直接返回，避免重复请求
- `openReleasePage()`：`availableUpdate` 非空时 `NSWorkspace.shared.open(url)`
- **菜单面板那个每 5 秒的刷新 Timer 不触发更新检查**

### 4. `macos/Sources/MenuPanel.swift`（修改）

footer 在「刷新」与「退出」之间插入一个按钮：

| 状态 | 按钮文字 | 样式 | 点击行为 |
|---|---|---|---|
| 无新版 | `检查更新` | 默认 | `checkForUpdates(manual: true)` |
| 检查中 | `检查更新` | 禁用 | — |
| 有新版 | `更新到 v0.4.0` | 强调色 + `arrow.down.circle` 图标 | `openReleasePage()` |

- 有新版时 `.help(release.notes)`，悬停可见更新说明
- `updateMessage` 非空时，footer 下方渲染一行 11pt 灰色小字；清空由 model 负责，UI 只读状态

### 5. 统一 App 名字（修改 `macos/build.sh`）

现状分裂：

| 产物 | 装出来的路径 |
|---|---|
| `build.sh install` | `/Applications/NetSplit.app` |
| `pkg` | `/Applications/NetSplit.app` |
| `dmg` | `/Applications/网卡分流.app` |

用户从 Release 下 DMG 拖进去得到「网卡分流.app」，而此前 `build.sh install` 装的是 `NetSplit.app`，两者并存且登录项指着旧的那个——"更新完了却没变化"。

统一为 `网卡分流.app`（与 `CFBundleDisplayName` 一致）：

- `build.sh` 的 `install` 分支：`DEST="/Applications/${DISPLAY_NAME}.app"`
- `build.sh` 的 `build_pkg`：payload 内的 app 目录名改用 `${DISPLAY_NAME}.app`
- `macos/packaging/postinstall`：`APP="/Applications/NetSplit.app"` 改为 `/Applications/${DISPLAY_NAME}.app`（写死的，不改则 pkg 装完不会自动启动）
- DMG 已经是 `${DISPLAY_NAME}.app`，无需改

不需要改的：

- `macos/packaging/preinstall` 的 `pkill -x NetSplit` 用的是**可执行文件名**，而 `CFBundleExecutable` 保持 `NetSplit` 不变，故不受影响
- bundle id 保持 `com.weiyuhang.netsplit`，`SMAppService` 登录项注册不受影响
- `build.sh` 的 `build_app` 产出路径 `build/NetSplit.app` 是构建中间产物，与安装名无关，保持原样

存量迁移：项目尚未对外发布，无存量用户，不需要迁移逻辑。

### 6. `macos/Tests/version_test.swift`（新增）

不引入 SPM，直接用 swift 解释器模式跑：

```bash
swift macos/Tests/version_test.swift macos/Sources/Version.swift
```

覆盖上表中全部用例，另加：

- 空字符串、`"abc"` 等非法输入不崩溃
- `1.0.0` vs `1.0.0.0` 等值
- 大版本号进位（`0.10.0` > `0.9.0`，防字符串比较错误）

脚本以非零退出码表示失败。

## 明确不做（YAGNI）

- 不自动下载安装包
- 不自动替换 / 重启 app
- 不记住「跳过此版本」
- 不做增量更新
- 不提供镜像 / 自定义 API 地址配置
- 不校验安装包哈希或签名
- 不在菜单栏图标上加角标

## 错误处理

| 场景 | 表现 |
|---|---|
| 启动时自动检查失败（断网、被墙、限流） | 完全静默，无任何 UI 变化 |
| 手动检查失败 | footer 下方灰字「检查更新失败」，3 秒后消失；按钮保持可用 |
| 手动检查已是最新 | footer 下方灰字「已是最新」，3 秒后消失 |
| API 返回非法 JSON / 缺字段 | 归入 `.failed` |
| 当前版本取不到 | 归入 `.failed`（静默） |

## 测试策略

- `Version` 的版本比较：`macos/Tests/version_test.swift`，覆盖上表全部用例 + 边界输入
- `UpdateChecker` 的网络路径：不做自动化测试（无 mock 基础设施）；靠手动验证——分别在有网、断网、以及把仓库地址临时改错三种情况下各点一次「检查更新」
- UI：手动验证三个状态（无新版 / 有新版 / 检查失败）
