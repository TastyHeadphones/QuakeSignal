<div align="right">

[English](README.md) · [简体中文](README.zh-CN.md)

</div>

<div align="center">

<img src="ios/QuakeSignal/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="112" alt="QuakeSignal アプリアイコン" />

# 震息 · QuakeSignal

### iPhone・Chrome・macOS・Windows 向けの地震情報、周辺警報、そして防災ガイド。

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-0E63C4?logo=apple&logoColor=white)](ios/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](ios/QuakeSignal/)
[![Tauri 2](https://img.shields.io/badge/desktop-Tauri_2-24C8DB?logo=tauri&logoColor=white)](desktop/)
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
> QuakeSignal は独立した非公式アプリです。地震情報は第三者が集約したデータに
> 基づいており、遅延・欠落・訂正・不正確が生じる場合があります。必ず公式発表と
> 地域の緊急指示に従ってください。

## できること

| | 機能 | 内容 |
|---|---|---|
| 📡 | リアルタイム地震データ | JMA・CENC・四川・福建・重慶をカバーする Wolfx の7系統のフィードを正規化。 |
| 📍 | 周辺の状況 | 選択した都市または現在地を基準に、距離・方角・半径・マグニチュードで絞り込み。 |
| ⚠️ | 明確な警報状態 | 速報・更新・最終報・キャンセル・訓練を区別し、色だけに頼らない表示。 |
| 🖥️ | ローカルファーストのデスクトップ | 上流の WebSocket に直接接続し、データは端末内に保存。QuakeSignal のバックエンドなしでトレイからネイティブ警報を鳴らせます。 |
| 🌐 | Chrome 拡張 | 同じ直接接続のフィードをブラウザで監視し、履歴を端末内に保存。通知と警報音に対応。 |
| ♿ | アクセシビリティ対応 | Dynamic Type、VoiceOver に配慮したラベル、44pt のタップ領域、高コントラスト表示に対応。 |

## アーキテクチャ

iOS・macOS・Windows は地震データをすべて Wolfx から直接取得します。Cloudflare の
役割は一つだけです。iOS がバックグラウンドまたは終了中でも警報を監視し、条件に
合う通知を APNs で配信します。

- [`ios/`](ios/) —— iOS 17+ 向けのネイティブ SwiftUI アプリ（Swift 6）
- [`desktop/`](desktop/) —— macOS / Windows 向けのローカルファースト Tauri アプリ
- [`extension/`](extension/) —— Manifest V3 の Chrome 拡張
- [`backend/cloudflare/`](backend/cloudflare/) —— 通知専用の Worker と D1
- [`docs/WOLFX_API.md`](docs/WOLFX_API.md) —— 実レスポンスで検証した上流フィールド仕様
- [`docs/DESIGN_PROMPT.md`](docs/DESIGN_PROMPT.md) —— プロダクト/ビジュアル設計仕様

## macOS へのインストール

現在、サポート対象の公開 macOS ダウンロード版および Homebrew cask はありません。
現行の GitHub Release `v0.1.0` は Developer ID 署名と公証より前のものであり、
`TastyHeadphones/tap` には公開 cask もありません。どちらもインストールしないでください。
後続の GitHub Release に Developer ID 署名・公証・staple 済みの universal DMG と
`SHA256SUMS.txt` が示された後、`QuakeSignal_<バージョン>_universal.dmg` をダウンロードして
開き、**QuakeSignal** をアプリケーションフォルダにドラッグします。Homebrew は、その
同じ公証済みリリースの cask が公開 tap に反映された後にのみ使用できます:

```bash
# 公開 tap に対象の公証済みリリース用 cask がある場合にのみ実行します。
brew tap TastyHeadphones/tap
brew install --cask quakesignal
```

### Gatekeeper と公証

保護された macOS リリースジョブは、直接配布/Homebrew 用アプリを **Developer ID
Application** 証明書で署名し、公証後に DMG へチケットを staple します。
`SHA256SUMS.txt` があり、macOS 成果物が公証済みと示されるリリースだけを使用してください。

隔離属性の削除や Gatekeeper の回避は行わないでください。この手順で作成されたリリースが
macOS によりブロックされた場合は、`SHA256SUMS.txt` と照合し、ダウンロードファイルを
保持したままリリース URL と macOS バージョンを issue で報告してください。旧 `v0.1.0`
リリースはサポート対象のインストール元または cask のソースではありません。

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

将来の公開 Homebrew cask から導入した場合:

```bash
brew uninstall --cask quakesignal
```

それ以外の場合は、アプリケーションフォルダの **QuakeSignal** をゴミ箱に移動します。

設定と履歴も削除する場合は、次を削除してください。

```bash
rm -rf ~/Library/Application\ Support/com.quakesignal.desktop
```

`brew uninstall --cask --zap quakesignal` を使えば、アプリと上記ディレクトリを
まとめて削除できます。

## クイックスタート

**iOS** —— `ios/QuakeSignal.xcodeproj` を Xcode で開き、シミュレータを選んで
`QuakeSignal` スキームを実行します。地震データは Wolfx から直接取得し、
Cloudflare は通知登録にのみ使用します。プッシュ通知には実機、Apple Developer
チーム、APNs 認証情報が必要です。

**デスクトップ** —— デスクトップ版は Wolfx に直接接続し、どちらのバックエンドも
必要としません。

```bash
cd desktop
npm ci
npm run tauri dev
```

**Chrome** —— `chrome://extensions` でデベロッパーモードを有効にし、
**パッケージ化されていない拡張機能を読み込む**から `extension/` を選択します。

## iOS 本番リリースの前提条件

公開 iOS リリースの前に、次を完了してください。

- ユーザー承認済みの本番 Cloudflare Workers endpoint
  `https://quakesignal-api.hopeso.workers.dev`、その公開 TLS、および `/healthz` を
  確認します。別の `workers.dev` hostname は隔離された Debug/staging 用だけであり、
  Release の代替には使いません。
- `com.quakesignal.app` で App Attest を有効にし、本番用 provisioning profile を
  更新して、本番 Worker の App Attest 必須モードを維持します。
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

macOS の直接配布版が公開される場合は、`SHA256SUMS.txt` を含み、Developer ID で
署名・公証・staple されたものになります。Mac App Store 用の sandbox 化された
パッケージはその後に別の非公開 Actions artifact として作成でき、公開 GitHub
Release には添付されません。

## ライセンス

QuakeSignal は [MIT License](LICENSE) のもとで公開されています。
