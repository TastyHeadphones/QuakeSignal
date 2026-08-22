<div align="right">

[English](README.md) · [日本語](README.ja.md)

</div>

<div align="center">

<img src="ios/QuakeSignal/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="112" alt="QuakeSignal 应用图标" />

# 震息 · QuakeSignal

### 面向各 Apple 平台、Chrome 与 Windows 的地震速报、附近预警与防灾指南。

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-0E63C4?logo=apple&logoColor=white)](ios/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](ios/QuakeSignal/)
[![Tauri 2](https://img.shields.io/badge/Windows-Tauri_2-24C8DB?logo=tauri&logoColor=white)](desktop/)
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
> QuakeSignal 是独立的非官方应用。Apple 版 1.1 显示由 Wolfx 中继的日本气象厅发布信息，
> 可能存在延迟、缺失、修订或误差。请始终以官方公告和当地应急指示为准。

## 功能

| | 能力 | 说明 |
|---|---|---|
| 📡 | 实时地震数据 | 提交的 Apple 版仅使用 Wolfx 的 `jma_eew` 与 `jma_eqlist`，显示日本气象厅发布的信息。 |
| 📍 | 附近情境 | 以所选城市或当前位置为基准，提供距离、方位、半径与震级筛选。 |
| ⚠️ | 清晰的警报状态 | 区分预警、更新、最终报、取消与训练报，颜色绝不是唯一的提示手段。 |
| 🖥️ | 原生 Mac 应用 | 与 SwiftUI Apple 应用共享地图、警报策略与设置的沙盒 Mac Catalyst 版本。 |
| 🪟 | Windows 应用 | 单独维护的 Tauri 客户端，直连上游 WebSocket 并在本地保存数据。 |
| 🌐 | Chrome 扩展 | 在浏览器中监测同样的直连数据源，本地保存历史，支持通知与警报声。 |
| ♿ | 无障碍设计 | 支持动态字体、VoiceOver 友好标签、44pt 触控目标与高对比度状态呈现。 |

## 架构

提交的 SwiftUI Apple 应用仅直接读取 Wolfx 的日本气象厅 EEW 与地震信息两条路径。
Cloudflare 也只监测这两条路径，用于在 iPhone/iPad 进入后台或退出时通过 APNs
发送匹配通知。另行维护的 Windows 与 Chrome 客户端不属于 Apple build 8 的发布边界。

- [`ios/`](ios/) —— iPhone、iPad、Watch、TV、Vision Pro 与 Mac Catalyst 共享的原生 SwiftUI 应用，使用 Swift 6
- [`desktop/`](desktop/) —— 另行维护的 Windows Tauri 客户端，不是 build 8 的 Mac App Store 产品
- [`extension/`](extension/) —— Manifest V3 Chrome 扩展
- [`backend/cloudflare/`](backend/cloudflare/) —— 仅负责通知的 Worker 与 D1
- [`docs/WOLFX_API.md`](docs/WOLFX_API.md) —— 对照真实响应核实过的上游字段文档
- [`docs/DESIGN_PROMPT.md`](docs/DESIGN_PROMPT.md) —— 产品与视觉设计规范

## 在 macOS 上安装

版本 1.1 的 Mac 发布路径，是共用 QuakeSignal App Store 记录中的沙盒 SwiftUI
Mac Catalyst 应用。在签名 build 8、当前截图、Mac 实机 QA 与 App Review 门槛全部
通过前不会公开；公开后请仅从 Mac App Store 安装。

旧 Tauri `v0.1.0` GitHub Release、直接下载 DMG 与 Homebrew cask 均已休止，
不是本次发布支持的 Mac 安装路径。请勿绕过 Gatekeeper 安装它们。

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

通过启动台删除，或把“应用程序”文件夹中的 **QuakeSignal** 拖到废纸篓。Mac App Store
版的沙盒属于 bundle ID `com.quakesignal.app`；仅当你也要清除设置与本地状态时，才删除
`~/Library/Containers/com.quakesignal.app/`。

## 快速开始

**SwiftUI Apple 应用** —— 用 Xcode 打开 `ios/QuakeSignal.xcodeproj`，选择 iPhone、
iPad 或 Mac Catalyst destination，运行 `QuakeSignal` scheme。地震数据直接来自 Wolfx；
Cloudflare 仅用于通知注册。推送通知需要真机、
Apple 开发者团队与 APNs 凭证。

**单独的 Tauri 客户端** —— 仅用于 Windows 开发，并非 build 8 的 Mac App Store 路径。
它直连 Wolfx，不需要两个后端：

```bash
cd desktop
npm ci
npm run tauri dev
```

**Chrome** —— 打开 `chrome://extensions`，启用开发者模式，点击“加载已解压的扩展程序”并选择 `extension/`。

## Apple 各平台正式发布前提

公开发布 Apple 各平台前，请完成以下事项：

- 验证用户批准的生产 Cloudflare Workers endpoint
  `https://quakesignal-api.hopeso.workers.dev`、其公开 TLS 和 `/` 服务元数据。
  其他 `workers.dev` hostname 仅限隔离的 Debug/staging 服务，绝不能作为 Release
  备用地址。
- 确认已注册的 `com.quakesignal.app`、Watch App ID 与已审核 capability，并从 Xcode
  2026-08-22 账户审计确认尚未配置 Xcode Cloud workflow。本次发布禁止使用本地 Xcode，
  因此应使用配置了五个已审核分发 profile 的受保护 GitHub build-8 workflow。所有签名 run
  必须固定到冻结的完整 source SHA，并在 TestFlight QA 前验证机器可读的签名 artifact 证明。
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

Mac App Store 产品是随原生 Apple 发布统一构建和签名的沙盒 SwiftUI Mac Catalyst target。
旧 Tauri Mac 记录与直接下载计划在版本 1.1 中保持休止。

## 许可证

QuakeSignal 基于 [MIT License](LICENSE) 发布。
