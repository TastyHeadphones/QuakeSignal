<div align="right">

[English](README.md) · [简体中文](README.zh-CN.md)

</div>

<div align="center">

<img src="ios/QuakeSignal/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="112" alt="QuakeSignal アプリアイコン" />

# 震息 · QuakeSignal

### Apple 各プラットフォーム・Chrome・Windows 向けの地震情報、周辺警報、防災ガイド。

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-0E63C4?logo=apple&logoColor=white)](ios/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](ios/QuakeSignal/)
[![Tauri 2](https://img.shields.io/badge/Windows-Tauri_2-24C8DB?logo=tauri&logoColor=white)](desktop/)
[![Chrome MV3](https://img.shields.io/badge/Chrome-Manifest_V3-4285F4?logo=googlechrome&logoColor=white)](extension/)
[![MIT License](https://img.shields.io/badge/license-MIT-30B14F)](LICENSE)
[![コード署名ポリシー](https://img.shields.io/badge/code_signing-policy-6E56CF)](docs/SIGNING.md)
[![プライバシーポリシー](https://img.shields.io/badge/privacy-policy-0A3D73)](docs/PRIVACY.md)

**[macOS 配布状況](#macos-へのインストール)** ·
**[Microsoft Store（Windows）](https://apps.microsoft.com/detail/9N730S3CZ7Z9)** ·
[macOS へのインストール](#macos-へのインストール) ·
[アンインストール](#アンインストール) ·
[コード署名ポリシー](#コード署名ポリシー) ·
[プライバシーポリシー](docs/PRIVACY.md)

</div>

> [!IMPORTANT]
> QuakeSignal は独立した非公式アプリです。Apple 向け build 1.1 は、Wolfx が中継する
> 気象庁発表の情報を表示します。遅延・欠落・訂正・誤差が生じる場合があるため、
> 必ず公式発表と地域の緊急指示に従ってください。

## できること

| | 機能 | 内容 |
|---|---|---|
| 📡 | リアルタイム地震データ | 提出する Apple 版では Wolfx の `jma_eew` と `jma_eqlist` のみを使用し、気象庁発表の情報を表示。 |
| 📍 | 周辺の状況 | 選択した都市または現在地を基準に、距離・方角・半径・マグニチュードで絞り込み。 |
| ⚠️ | 明確な警報状態 | 速報・更新・最終報・キャンセル・訓練を区別し、色だけに頼らない表示。 |
| 🖥️ | ネイティブ Mac アプリ | SwiftUI の Apple アプリ、地図、警報ポリシー、設定を共有する sandbox 化された Mac Catalyst 版。 |
| 🪟 | Windows アプリ | 別系統の Tauri クライアント。上流 WebSocket に直接接続し、データを端末内に保存。 |
| 🌐 | Chrome 拡張 | 同じ直接接続のフィードをブラウザで監視し、履歴を端末内に保存。通知と警報音に対応。 |
| ♿ | アクセシビリティ対応 | Dynamic Type、VoiceOver に配慮したラベル、44pt のタップ領域、高コントラスト表示に対応。 |

## アーキテクチャ

提出する SwiftUI Apple アプリは、Wolfx の気象庁 EEW・地震情報の2経路だけを直接
取得します。Cloudflare は同じ2経路だけを監視し、iPhone/iPad がバックグラウンド
または終了中のときに条件に合う通知を APNs で配信します。別系統の Windows と
Chrome クライアントは Apple build 8 のリリース境界外です。

- [`ios/`](ios/) —— iPhone・iPad・Watch・TV・Vision Pro・Mac Catalyst で共有するネイティブ SwiftUI アプリ（Swift 6）
- [`desktop/`](desktop/) —— Windows 用に別途保守する Tauri クライアント。build 8 の Mac App Store 製品ではありません
- [`extension/`](extension/) —— Manifest V3 の Chrome 拡張
- [`backend/cloudflare/`](backend/cloudflare/) —— 通知専用の Worker と D1
- [`docs/WOLFX_API.md`](docs/WOLFX_API.md) —— 実レスポンスで検証した上流フィールド仕様
- [`docs/DESIGN_PROMPT.md`](docs/DESIGN_PROMPT.md) —— プロダクト/ビジュアル設計仕様

## macOS へのインストール

バージョン 1.1 の Mac 配布経路は、共通の QuakeSignal App Store レコードで提供する
sandbox 化された SwiftUI Mac Catalyst アプリです。署名済み build 8、現行スクリーン
ショット、Mac 実機 QA、App Review の各ゲートを通過するまでは公開されません。公開後は
Mac App Store からのみインストールしてください。

旧 Tauri `v0.1.0` の GitHub Release、直接配布 DMG、Homebrew cask は休止中であり、
このリリースのサポート対象 Mac インストール経路ではありません。Gatekeeper を回避して
インストールしないでください。

## Windows へのインストール

[Microsoft Store](https://apps.microsoft.com/detail/9N730S3CZ7Z9) から
QuakeSignal をダウンロードしてください。Store のパッケージは Microsoft により
認定・署名されています。利用可否は Store の公開地域によって異なります。

## アンインストール

QuakeSignal はアプリ本体の場所と専用のデータディレクトリ以外には書き込みません。
この2つを削除すれば何も残りません。

### Windows

標準の方法 —— **設定 → アプリ → インストールされているアプリ → QuakeSignal →
アンインストール** —— を使うか、インストール先フォルダ内のアンインストーラーを
実行します。`.exe` と `.msi` のどちらのパッケージもアンインストーラーを登録します。

設定と履歴も削除する場合は、次を削除してください。

```
%APPDATA%\com.quakesignal.desktop\
```

### macOS

Launchpad から削除するか、アプリケーションフォルダの **QuakeSignal** をゴミ箱へ
移動します。Mac App Store 版の sandbox は bundle ID `com.quakesignal.app` に属します。
設定とローカル状態も消去する場合に限り、`~/Library/Containers/com.quakesignal.app/`
を削除してください。

## クイックスタート

**SwiftUI Apple アプリ** —— `ios/QuakeSignal.xcodeproj` を Xcode で開き、iPhone、
iPad、または Mac Catalyst の destination を選んで `QuakeSignal` スキームを実行します。
地震データは Wolfx から直接取得し、
Cloudflare は通知登録にのみ使用します。プッシュ通知には実機、Apple Developer
チーム、APNs 認証情報が必要です。

**別系統の Tauri クライアント** —— Windows 開発用に残しており、build 8 の Mac App
Store 経路ではありません。Wolfx に直接接続し、どちらのバックエンドも必要としません。

```bash
cd desktop
npm ci
npm run tauri dev
```

**Chrome** —— `chrome://extensions` でデベロッパーモードを有効にし、
**パッケージ化されていない拡張機能を読み込む**から `extension/` を選択します。

## Apple 各プラットフォームの本番リリース前提条件

Apple 各プラットフォームを公開する前に、次を完了してください。

- ユーザー承認済みの本番 Cloudflare Workers endpoint
  `https://quakesignal-api.hopeso.workers.dev`、その公開 TLS、および `/` のサービスメタデータを
  確認します。別の `workers.dev` hostname は隔離された Debug/staging 用だけであり、
  Release の代替には使いません。
- 登録済みの `com.quakesignal.app` と Watch App ID、および審査済み capability を確認し、
  2026-08-22 のアカウント監査で Xcode Cloud workflow が未設定であることを確認します。
  このリリースではローカル Xcode を使えないため、5つの審査済み配布 profile を設定した
  保護済み GitHub build-8 workflow を使用します。すべての署名 run を凍結した完全な source
  SHA に固定し、TestFlight QA 前に機械可読な署名 artifact 証明を検証します。
- Debug と Simulator は本番データや認証情報を共有しない別の staging Worker を使います。
  実機で APNs/App Attest、登録・削除・トークン更新を確認し、その後ユーザー承認済みの
  本番 endpoint に対する TestFlight APNs テストを完了してから reviewer の承認を受けます。
- 最初の本番 Worker デプロイでは、保護されたワークフローで
  `bootstrap_testflight=true` を指定し、`APP_ATTEST_PRODUCTION_ENFORCED` を `false`
  にします。これは本番 App Attest、APNs、承認済み Worker endpoint を引き続き必須にした
  非公開 TestFlight 検証専用の段階です。実機検証後に変数を `true` に変更し、通常の
  launch 段階を再実行してから、App Review への提出または公開リリースを行います。

## ローカライズ

ユーザー向けの画面はすべて英語（`en`）、日本語（`ja`）、簡体字中国語
（`zh-Hans`）に対応しています。

## コード署名ポリシー

QuakeSignal のコード署名ポリシー —— 何に署名するのか、リリースをどうビルドするの
か、誰が署名を承認できるのか —— は
[`docs/SIGNING.md`](docs/SIGNING.md) に記載しています。プライバシーについては
[`docs/PRIVACY.md`](docs/PRIVACY.md) を参照してください。

**チームの役割。** QuakeSignal はメンテナー1名のプロジェクトです。
[@TastyHeadphones](https://github.com/TastyHeadphones) が Author・Reviewer・
Approver の3つの役割すべてを担います。外部からのプルリクエストはすべてメンテナー
のレビューを経てからマージされ、署名リクエストは毎回メンテナーの明示的な承認を
必要とします。タグを push しただけでは署名は行われません。

各リリースでは、すべての成果物を対象とした `SHA256SUMS.txt` を公開しています。
デスクトップ版のバイナリはバージョンタグから GitHub Actions のみでビルドされ、
メンテナーのマシンからアップロードされることはありません。

Windows リリースは GitHub Actions で MSIX パッケージとしてビルドされ、Microsoft
Store を通じて配布されます。認定済みの Store パッケージは Microsoft が署名し、
このプロジェクトで Windows 用の署名鍵や第三者の署名サービスは使用しません。

Mac App Store 製品は、ネイティブ Apple リリースと一体で build・署名する sandbox 化
された SwiftUI Mac Catalyst target です。旧 Tauri Mac レコードと直接配布計画は
バージョン 1.1 では休止します。

## ライセンス

QuakeSignal は [MIT License](LICENSE) のもとで公開されています。
