<div align="right">

[English](README.md) · [日本語](README.ja.md)

</div>

<div align="center">

# 震息 · QuakeSignal

**原生 iOS 地震预警应用 —— 支持英语、日本語、简体中文。**
通过 [Wolfx Open API](https://wolfx.jp) 转发日本气象厅（JMA）、中国地震台网中心
（CENC）以及四川、福建、重庆地震局的官方预警，在预警发布后的几秒内把警报送到用户
面前——哪怕应用已经被关闭。

</div>

<p align="center">
  <img src="docs/screenshots/app-home-en.png" width="200" alt="首页 - 英文" />
  <img src="docs/screenshots/app-home-ja.png" width="200" alt="首页 - 日文" />
  <img src="docs/screenshots/app-home-zh.png" width="200" alt="首页 - 简体中文" />
</p>

<p align="center"><sub>真实的 Simulator 截图 —— 用 <code>xcodebuild</code> 编译，连接真实后端与真实 Wolfx 数据跑起来的，同一份构建切换三种语言。</sub></p>

## 整体架构

iOS 不允许应用在后台或被杀死时保持 WebSocket 连接常开——想让"哪怕锁屏也要立刻响"
的生命安全警报送达，唯一办法就是靠服务端常驻连接，再通过 Apple 推送服务（APNs）
转发。所以 iOS 应用从不直接连接 Wolfx，只和自己的后端打交道。

```mermaid
flowchart LR
    subgraph wolfx["Wolfx Open API · 7 个 WebSocket 数据源"]
        direction TB
        jma["JMA 地震预警"]
        cenc["CENC 地震预警"]
        sc["四川 / 福建 / 重庆 地震预警"]
        eq["CENC + JMA 地震列表"]
    end

    subgraph backend["backend/ · 常驻 Node.js 中转服务"]
        direction TB
        relay["自动重连 WS 客户端"] --> norm["标准化 + 去重\n（各数据源字段差异只在这里处理一次）"]
        norm --> db[("SQLite")]
    end

    subgraph ios["ios/ · SwiftUI 应用"]
        direction TB
        fg["前台：REST 历史记录\n+ 实时 WebSocket"]
        bg["后台 / 锁屏 / 被杀死：\nAPNs 推送，本地 loc-key 多语言"]
    end

    wolfx -- "WebSocket" --> relay
    db -- "REST /v1/quakes" --> fg
    backend -- "WebSocket /v1/live" --> fg
    backend -- "APNs" --> bg
```

- [`ios/`](ios/) —— SwiftUI 应用（iOS 17+，Swift 6），Xcode 工程通过 XcodeGen 生成并已提交
- [`backend/`](backend/) —— 中转与推送服务，APNs 配置见 [backend/README.md](backend/README.md)
- [`docs/WOLFX_API.md`](docs/WOLFX_API.md) —— 对照真实返回数据核实过的 Wolfx 接口字段文档
- [`docs/DESIGN_PROMPT.md`](docs/DESIGN_PROMPT.md) —— 英文产品/设计说明书

## 快速开始

**后端**（必须先起，否则 app 里什么都看不到）：
```bash
cd backend
cp .env.example .env   # APNs 密钥可以先不填，本地开发不影响后端运行
npm install
npm run dev
```

**iOS** —— 用 Xcode 打开 `ios/QuakeSignal.xcodeproj`，选 Simulator 运行即可。
默认连接 `http://localhost:8080`（Simulator 天然能访问 Mac 自己的
localhost），配置见
[`ios/QuakeSignal/Networking/BackendConfig.swift`](ios/QuakeSignal/Networking/BackendConfig.swift)。
推送通知需要真机 + 真实 APNs 凭证，见 [backend/README.md](backend/README.md)。

## 当前状态

| 部分 | 状态 |
|---|---|
| 后端 | 7 个 Wolfx 数据源全部接入，带自动重连/退避、去重与更新判定、单个事件的速报修订历史、按距离/半径 + 夜间免打扰 + 演习信息的推送过滤、SQLite 存储、REST API、实时 WebSocket 广播、基于 `loc-key` 本地化的 APNs 推送。已用真实 Wolfx 数据做过冒烟测试。 |
| iOS | 5 个 tab（首页/列表/地图/指南/设置），已对齐设计稿：基于城市/GPS 的订阅与"距你多远"的位置化叙事贯穿全app、三态首页状态卡、带实时倒计时和"趴下-掩护-抓牢"插画的全屏预警（以及正式/取消/演习测试等独立状态）、带速报更新时间线的事件详情、可筛选的列表和地图、防灾指南（应对步骤、应急清单、本地家庭报平安）、独立的来源与免责声明页面，以及设计稿的精确配色 token 和 App 图标概念。完整的 en / ja / zh-Hans 三语本地化。在 Swift 6 严格并发模式下 `xcodebuild` 编译通过，已在 Simulator 上用三种语言、连真实数据实测跑通。 |

## 关于源设计稿

设计稿在一个 `claude.ai/design` 项目里（"震息 · QuakeSignal iOS App
Design"），一开始需要你自己的登录态才能访问。拿到授权之后发现这其实是一整套设计
系统：App 图标概念、颜色/字体/间距 token、组件表，以及引导页、首页（正常/注意/预
警/深色四种状态）、全屏地震预警、带速报更新时间线的事件详情、可筛选的列表和地
图、设置、防灾指南、空/加载/错误状态，以及关键页面的 en/ja/zh-Hans 本地化的高保
真页面——拿到访问权限之后这个项目是如何演进的，见 `docs/DESIGN_PROMPT.md` 里的
说明。上面这个 app 现在已经和设计稿高度一致；仍然存在的差距主要是像素级的布局还
原度，因为设计稿是用 HTML/CSS 做的，而 app 是原生 SwiftUI —— 结构、文案、配色
token 和交互流程都对齐了，但间距和排版是按平台习惯调整过的，不是逐像素测量还原
的。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
