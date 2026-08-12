<div align="right">

[English](README.md) · [日本語](README.ja.md)

</div>

<div align="center">

<img src="ios/QuakeSignal/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="112" alt="QuakeSignal 应用图标" />

# 震息 · QuakeSignal

### 面向 iPhone、Chrome、macOS 与 Windows 的地震速报、附近预警与防灾指南。

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-0E63C4?logo=apple&logoColor=white)](ios/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](ios/QuakeSignal/)
[![Tauri 2](https://img.shields.io/badge/desktop-Tauri_2-24C8DB?logo=tauri&logoColor=white)](desktop/)
[![Chrome MV3](https://img.shields.io/badge/Chrome-Manifest_V3-4285F4?logo=googlechrome&logoColor=white)](extension/)
[![MIT License](https://img.shields.io/badge/license-MIT-30B14F)](LICENSE)
[![代码签名政策](https://img.shields.io/badge/code_signing-policy-6E56CF)](docs/SIGNING.md)
[![隐私政策](https://img.shields.io/badge/privacy-policy-0A3D73)](docs/PRIVACY.md)

**[macOS 发布状态](#在-macos-上安装)** ·
**[Microsoft Store（Windows）](https://apps.microsoft.com/detail/9N730S3CZ7Z9)** ·
[在 macOS 上安装](#在-macos-上安装) ·
[卸载](#卸载) ·
[代码签名政策](#代码签名政策) ·
[隐私政策](docs/PRIVACY.md)

</div>

> [!IMPORTANT]
> QuakeSignal 是独立的非官方应用。地震信息来自第三方聚合数据源，可能出现延迟、
> 缺失、修订或不准确的情况。请始终以官方公告和当地应急指示为准。

## 功能

| | 能力 | 说明 |
|---|---|---|
| 📡 | 实时地震数据 | 归一化 Wolfx 的七路数据源，覆盖 JMA、CENC 以及四川、福建、重庆。 |
| 📍 | 附近情境 | 以所选城市或当前位置为基准，提供距离、方位、半径与震级筛选。 |
| ⚠️ | 清晰的警报状态 | 区分预警、更新、最终报、取消与训练报，颜色绝不是唯一的提示手段。 |
| 🖥️ | 本地优先的桌面端 | 直连上游 WebSocket，数据存在本地，可从托盘发出原生警报，无需 QuakeSignal 后端。 |
| 🌐 | Chrome 扩展 | 在浏览器中监测同样的直连数据源，本地保存历史，支持通知与警报声。 |
| ♿ | 无障碍设计 | 支持动态字体、VoiceOver 友好标签、44pt 触控目标与高对比度状态呈现。 |

## 架构

iOS、macOS 与 Windows 都直接从 Wolfx 获取地震数据。Cloudflare 只负责一件事：
在 iOS 处于后台或已退出时继续监测警报，并通过 APNs 推送匹配的通知。

- [`ios/`](ios/) —— 面向 iOS 17+ 的原生 SwiftUI 应用，使用 Swift 6
- [`desktop/`](desktop/) —— 面向 macOS 与 Windows 的本地优先 Tauri 应用
- [`extension/`](extension/) —— Manifest V3 Chrome 扩展
- [`backend/cloudflare/`](backend/cloudflare/) —— 仅负责通知的 Worker 与 D1
- [`docs/WOLFX_API.md`](docs/WOLFX_API.md) —— 对照真实响应核实过的上游字段文档
- [`docs/DESIGN_PROMPT.md`](docs/DESIGN_PROMPT.md) —— 产品与视觉设计规范

## 在 macOS 上安装

目前没有受支持的公开 macOS 下载版或 Homebrew cask。当前 GitHub Release `v0.1.0`
早于 Developer ID 签名和公证，`TastyHeadphones/tap` 也尚未发布 cask；请不要安装
其中任何一个。待后续 GitHub Release 标明 universal DMG 已由 Developer ID 签名、
完成公证和 stapled，并附带 `SHA256SUMS.txt` 后，再下载
`QuakeSignal_<版本>_universal.dmg`，打开后把 **QuakeSignal** 拖入“应用程序”文件夹。
只有该公证发行版的 cask 已同步到公开 tap 后，才能使用 Homebrew：

```bash
# 仅当公开 tap 已包含该公证发行版的 cask 时运行。
brew tap TastyHeadphones/tap
brew install --cask quakesignal
```

### Gatekeeper 与公证

受保护的 macOS 发布任务会使用 **Developer ID Application** 证书签名直接下载/Homebrew
版本，完成公证后将票据 stapled 到 DMG。请只使用包含 `SHA256SUMS.txt` 且注明 macOS
产物已公证的发行版。

不要清除隔离标记或绕过 Gatekeeper。若按此流程构建的版本仍被 macOS 阻止，请先用
`SHA256SUMS.txt` 验证校验值，保留下载文件，并在 issue 中提供发行版 URL 与 macOS
版本。旧的 `v0.1.0` 发行版不是受支持的安装来源或 cask 来源。

## 在 Windows 上安装

请从 [Microsoft Store](https://apps.microsoft.com/detail/9N730S3CZ7Z9)
下载 QuakeSignal。商店中的安装包已由微软认证并签名；是否可用取决于该商店
条目已发布的地区。

## 卸载

QuakeSignal 只写入自身的安装位置和数据目录，删除这两处即可清理干净。

### Windows

可以使用标准卸载方式 —— **设置 → 应用 → 已安装的应用 → QuakeSignal → 卸载**，
也可以运行安装目录内的卸载程序；`.exe` 与 `.msi` 两种安装包都会注册卸载项。

如需一并删除设置与历史记录，请删除：

```
%APPDATA%\com.quakesignal.desktop\
```

### macOS

若通过未来发布的公开 Homebrew cask 安装：

```bash
brew uninstall --cask quakesignal
```

否则把“应用程序”文件夹中的 **QuakeSignal** 拖到废纸篓。

如需一并删除设置与历史记录，请删除：

```bash
rm -rf ~/Library/Application\ Support/com.quakesignal.desktop
```

使用 `brew uninstall --cask --zap quakesignal` 可一步完成应用与该目录的删除。

## 快速开始

**iOS** —— 用 Xcode 打开 `ios/QuakeSignal.xcodeproj`，选择模拟器运行 `QuakeSignal` scheme。
地震数据直接来自 Wolfx；Cloudflare 仅用于通知注册。推送通知需要真机、
Apple 开发者团队与 APNs 凭证。

**桌面端** —— 桌面版直连 Wolfx，两个后端都不需要：

```bash
cd desktop
npm ci
npm run tauri dev
```

**Chrome** —— 打开 `chrome://extensions`，启用开发者模式，点击“加载已解压的扩展程序”并选择 `extension/`。

## iOS 正式发布前提

公开发布 iOS 前，请完成以下事项：

- 验证用户批准的生产 Cloudflare Workers endpoint
  `https://quakesignal-api.hopeso.workers.dev`、其公开 TLS 和 `/healthz`。
  其他 `workers.dev` hostname 仅限隔离的 Debug/staging 服务，绝不能作为 Release
  备用地址。
- 为 `com.quakesignal.app` 启用 App Attest，更新生产 provisioning profile，并让生产
  Worker 保持 App Attest 必需的强制模式。
- Debug 与 Simulator 必须使用不共享生产数据或凭据的独立 staging Worker。先在真机上
  完成 APNs/App Attest、注册/删除和令牌刷新测试，再针对用户批准的生产 endpoint 完成
  TestFlight APNs 测试，之后才能由 reviewer 批准。
- 首次生产 Worker 部署使用受保护工作流的 `bootstrap_testflight=true`，并将
  `APP_ATTEST_PRODUCTION_ENFORCED` 设为 `false`；它仍强制执行生产 App Attest、APNs、
  批准的 Worker endpoint，只用于未公开的 TestFlight 验证。完成真机验证后将变量改为
  `true`，再次运行正常 launch 阶段，才能提交 App Review 或公开发布。

## 本地化

所有面向用户的流程均提供英语（`en`）、日语（`ja`）与简体中文（`zh-Hans`）。

## 代码签名政策

QuakeSignal 的代码签名政策 —— 签名对象、发行版的构建方式、以及谁有权批准签名 ——
记录在 [`docs/SIGNING.md`](docs/SIGNING.md)。隐私相关内容单独记录在
[`docs/PRIVACY.md`](docs/PRIVACY.md)。

**团队角色。** QuakeSignal 由单一维护者维护。
[@TastyHeadphones](https://github.com/TastyHeadphones) 同时担任
Author、Reviewer 与 Approver 三种角色。所有外部 Pull Request 都由维护者审阅后
才能合并；每一次签名请求都必须由维护者手动批准，仅推送标签并不会产生签名。

每个发行版都会发布覆盖全部构建产物的 `SHA256SUMS.txt`。桌面端二进制文件仅由
GitHub Actions 从版本标签构建，绝不会从维护者的机器上传。

Windows 发行版由 GitHub Actions 构建为 MSIX，并通过 Microsoft Store 发布。
经认证的商店安装包由微软签名；本项目不使用 Windows 签名密钥或第三方签名服务。

macOS 直接下载版发布时将包含 `SHA256SUMS.txt`，并已完成 Developer ID 签名、公证和
stapled。届时可为 Mac App Store 构建独立的私有 Actions artifact sandbox 安装包，
它不会附加到公开 GitHub Release。

## 许可证

QuakeSignal 基于 [MIT License](LICENSE) 发布。
