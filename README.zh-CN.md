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

**[下载](https://github.com/TastyHeadphones/QuakeSignal/releases/latest)** ·
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

从[最新发行版](https://github.com/TastyHeadphones/QuakeSignal/releases/latest)
下载 `QuakeSignal_<版本>_universal.dmg`，打开后把 **QuakeSignal** 拖入
“应用程序”文件夹。也可以使用本项目的 Homebrew tap：

```bash
brew tap TastyHeadphones/tap
brew install --cask quakesignal
```

### 如果 macOS 提示“已损坏”或“无法验证开发者”

首次打开时，macOS 很可能拒绝启动，并提示
*“QuakeSignal 已损坏，无法打开。您应该将它移到废纸篓。”*
或 *“无法打开 QuakeSignal，因为无法验证开发者。”*

**应用并没有损坏，你的下载也没有问题。** Apple 只为经过*公证*（notarization）
的应用背书，而公证需要付费的 Apple Developer Program 会员资格，本项目目前还没有。
macOS 会给所有从网上下载的文件加上“隔离”标记，并拒绝打开无法追溯到注册开发者的
隔离应用。这个警告说的是缺少 Apple 注册，而不是文件损坏。如果想确认下载完整，
可以核对发行版中公布的 SHA256 校验值。

以下**任选其一**即可，每个安装版本只需操作一次。

**方式一 —— 清除隔离标记（一条命令）。**
打开**终端**（按 ⌘ + 空格，输入 `Terminal` 后回车），原样粘贴并回车：

```bash
xattr -dr com.apple.quarantine "/Applications/QuakeSignal.app"
```

成功时不会有任何输出。之后正常打开 QuakeSignal 即可。

**方式二 —— 在“系统设置”中放行。**

1. 双击 **QuakeSignal**，关掉警告弹窗。
2. 打开苹果菜单 → **系统设置** → **隐私与安全性**。
3. 向下找到**安全性**一节，会看到“已阻止 QuakeSignal 以保护 Mac”。
4. 点击**仍要打开**，确认**打开**，然后输入 Mac 密码。

> [!NOTE]
> 右键（或按住 Control 点按）→**打开**已经不再适用。Apple 在 macOS 15 Sequoia
> 中移除了该快捷方式，现在只能通过“系统设置”里的**仍要打开**放行未公证的应用。

Windows 版本不受上述影响。公证已在计划中，详见
[`docs/SIGNING.md`](docs/SIGNING.md)。

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

若通过 Homebrew tap 安装：

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

QuakeSignal 使用 SignPath Foundation 为 Windows 进行代码签名。签名私钥保存在
SignPath 的硬件安全模块中，绝不出现在本仓库、CI 或维护者的机器上。

Free code signing provided by [SignPath.io](https://signpath.io?utm_source=foundation&utm_medium=github&utm_campaign=quakesignal),
certificate by [SignPath Foundation](https://signpath.org/)。

> [!NOTE]
> SignPath Foundation 的申请仍在审核中，因此 Windows 签名虽已配置但尚未启用，
> macOS 版本也尚未公证。每个发行版都会说明其自身的签名状态。

## 许可证

QuakeSignal 基于 [MIT License](LICENSE) 发布。
