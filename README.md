# NetSplit

macOS 菜单栏小工具：同时连着 **Wi-Fi 和网线** 时，把默认上网切到 Wi-Fi，内网 / GitLab 留在网线。

A macOS menu bar app that splits traffic across two interfaces: Wi-Fi for the default internet path, Ethernet for LAN or GitLab.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![arm64](https://img.shields.io/badge/arch-arm64-lightgrey) ![license](https://img.shields.io/badge/license-MIT-green)

## 它做什么

插上网线时，macOS 默认几乎所有流量都走网线。NetSplit 只改**网络服务顺序**（可选再加 GitLab 主机路由）：

- **开启分流**：Wi-Fi 作为默认出口
- **网线**：继续承担局域网，或直连 GitLab
- **恢复**：网线重新排到第一

不是 VPN，也不接管全部数据包。Clash **TUN 模式**会抢走默认路由，这时应以 Clash 规则为准（见下方说明）。

## 安装

### 菜单栏 App

```bash
cd macos
./build.sh install    # 编译并拷到 /Applications
# 或
./build.sh dmg        # 生成可分发的 DMG
./build.sh pkg        # 生成 pkg 安装包
```

依赖：Xcode Command Line Tools（`swiftc`、`iconutil`）。目前只编 **Apple Silicon**。

打开后菜单栏会出现图标。切换服务顺序需要输入本机密码。

也可从 [Releases](https://github.com/Capyhw/NetSplit/releases) 下载 `.dmg` / `.pkg`。未做 Apple 公证，第一次打开请右键 → 打开。

## 发布 Release

版本号在 `macos/Info.plist` 的 `CFBundleShortVersionString`。打 tag 并推送后，GitHub Actions 会编译并创建 Release：

```bash
# 1. 改 Info.plist 版本，提交
# 2. 打 tag（与版本号一致）
git tag v0.3.0
git push origin v0.3.0
```

在仓库页面也可以：右侧 **Releases → Draft a new release → Choose a tag → 填标题 → Publish**。若已配置 Actions，推送 `v*` tag 会自动挂上安装包。

本地手动发布：

```bash
./macos/build.sh dist
gh release create v0.3.0 macos/build/*.dmg macos/build/*.pkg --generate-notes
```

## 设置

齿轮里可配：

| 项 | 含义 |
|---|---|
| 局域网代理 | 例如另一台电脑上的 Clash/HTTP 代理。**留空** = 不走代理，GitLab 走网线直连 |
| GitLab 域名 | 用来探测网线能否访问（绑定网线网卡测 80/443） |
| 网卡 | 一般自动识别；USB 网卡名字特殊时再手选 |
| 从 gitconfig 读取 | 导入全局 `http.proxy` / `http.<url>.proxy` |

配置文件：`~/.config/net-split/config.json`

```json
{
  "proxyHost": "",
  "proxyPort": 0,
  "probeHost": "",
  "ethernetService": "",
  "wifiService": ""
}
```

## Clash TUN

NetSplit 改的是系统服务顺序。Clash / mihomo **TUN** 会再插 `utun` 并接管默认路由，普通上网不再跟服务顺序走。

- 继续用 NetSplit：关掉 Clash TUN，只用系统代理
- 必须开 TUN：在 Clash 里用 `type: direct` + `interface-name` 把内网绑到网线，并排除局域网网段

## 开发

```
macos/
  Sources/                # SwiftUI 菜单栏
  Resources/icon-1024.png
  build.sh                # build | open | install | pkg | dmg | dist
  packaging/              # pkg 脚本、SetIcon
```

需要管理员权限的操作通过 `osascript` 的 `do shell script … with administrator privileges` 执行。

## License

MIT
