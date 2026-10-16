[한국어](README.md) | [English](README.en.md) | **日本語**

# App Cleaner（仮称）

macOS アプリを残存ファイルまで含めて**安全に、元に戻せる形で**削除するツールです。削除済みアプリが残した孤立ファイルを見つけて整理することもできます。

- 設計: [docs/plan.md](docs/plan.md), [docs/ui-ux.md](docs/ui-ux.md)
- 開発: [docs/development.md](docs/development.md)

動作要件: macOS 14 以降、Swift 6（Command Line Tools または Xcode）。

## ビルド

```sh
./scripts/build-app.sh                 # dist/App Cleaner.app（ad-hoc 署名）
open "dist/App Cleaner.app"            # 実エンジン
open -n "dist/App Cleaner.app" --args --demo   # ダミーデータで画面を確認
./scripts/test.sh                      # テスト
```

## インストール（Apple シリコン）

> **App Cleaner は Apple の公証（notarization）を受けていません。** ソースを公開しており、このリポジトリの GitHub Actions がそのソースから
> ビルドした ad-hoc 署名のバイナリを [Releases](https://github.com/dallisoft/app-cleaner/releases) に置いています
> （[`release.yml`](.github/workflows/release.yml)、ビルドの記録は Actions タブ）。
> そのため初回起動時に macOS の Gatekeeper にブロックされます。下記の[初回起動](#初回起動--gatekeeper-で許可する)の手順で**一度だけ**許可してください。
> ビルド済みバイナリを使いたくない場合は[ビルド](#ビルド)のとおり自分でビルドするか、CLI は Homebrew（ソースからビルド）でインストールしてください。

### 入手するファイル

| ファイル | 内容 |
|---|---|
| `AppCleaner-<バージョン>-macos-arm64.dmg` | **アプリ（推奨）** — 開いて App Cleaner を「アプリケーション」へドラッグ |
| `AppCleaner-<バージョン>-macos-arm64.zip` | アプリ（DMG と同じ） |
| `appcleaner-<バージョン>-macos-arm64.tar.gz` | CLI 単体（実行ファイルと同じ場所に `AppCleaner_CleanerCore.bundle` を置く） |
| `SHA256SUMS.txt` | 上記ファイルの SHA-256 |

ダウンロードしたファイルがリリースと同じものか確認します（推奨）:

```sh
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt --ignore-missing   # ダウンロードした各ファイルが OK
```

### インストール

1. DMG を開き、**App Cleaner を「アプリケーション」フォルダへドラッグ**します（zip の場合は展開したアプリを「アプリケーション」へ移動）。
2. 必ず**「アプリケーション」に移動してから**起動します。DMG のウインドウやダウンロードフォルダから直接開くと、macOS がアプリを一時的な場所（App Translocation）から実行します。

### 初回起動 — Gatekeeper で許可する

初めて開くと警告が表示され、アプリは起動しません。公証されていないアプリでは正常な動作です。
「“App Cleaner”は開かれていません」— Apple はマルウェアが含まれていないことを確認できない、という内容で、**完了** と **ゴミ箱に入れる** ボタンがあります
（macOS のバージョンにより文言が少し異なる場合があります）。

**完了** を押してから（ゴミ箱に入れる ✗）、次のどちらかで許可します。

**方法 1 — システム設定（ターミナルなし）**

1. **システム設定 › プライバシーとセキュリティ** を開き、いちばん下の **セキュリティ** の項目までスクロールします。
2. App Cleaner がブロックされたという表示の横にある **このまま開く** を押します。
   このボタンはアプリを開こうとしてから約 1 時間だけ表示されます。見当たらない場合はアプリをもう一度開いてから確認してください。
3. パスワードまたは Touch ID で確認します。
4. もう一度確認ウインドウが表示されたら **このまま開く** を押します。以降は普通に起動します。

**方法 2 — ターミナル（1 行）**

```sh
xattr -dr com.apple.quarantine "/Applications/App Cleaner.app"
open "/Applications/App Cleaner.app"
```

`xattr -dr` は、ダウンロードしたファイルに付く「隔離（quarantine）」属性を**このアプリについてだけ**取り除きます。アプリの署名や Mac の Gatekeeper の設定は
変更しません。通常 `sudo` は不要です。許可のダイアログなしで起動し、App Translocation も起きません。

補足

- どちらの方法でも、許可は**アプリ内の Sentinel（メニューバーのゴミ箱監視）と CLI（`Contents/Helpers/appcleaner`）にも適用**されます。
- macOS 14（Sonoma）では Finder でアプリを Control-クリック › **開く** › **開く** でも許可できます。macOS 15 以降はこの方法が使えないため、上記の方法を使ってください。
- 許可はそのバージョン（コード）にだけ適用されます。**新しいバージョンに更新したら、もう一度許可**してください。
- 「壊れているため開けません」と表示される場合は、ダウンロードが壊れているか、展開時に署名が損なわれています。
  チェックサムを確認して再ダウンロードし DMG からインストールしてください。それでも同じなら方法 2 を使います。

### 初回起動のあと

- オンボーディング画面の案内に従って App Cleaner に **フルディスクアクセス** を許可します（システム設定 › プライバシーとセキュリティ › フルディスクアクセス）。
  他のアプリのコンテナを読むのに必要で、ゴミ箱の監視（Sentinel）も同じ権限を使います — Sentinel は一覧に別項目としては表示されません。
- 設定 › ゴミ箱の監視 または 定期スキャンの通知 をオンにすると、Sentinel がログイン項目として登録されます。macOS が App Cleaner がバックグラウンドで
  実行できるという通知を表示し、「App Cleaner Sentinel」の通知を許可するかを尋ねます。
- 管理者操作（システムフォルダの項目の整理・復元）では管理者パスワードを求めます。特権ヘルパーは Developer ID で署名したビルドでのみ動作するため、公式リリースでは使いません。

### アップデート・削除

- **アップデート**: 新しいバージョンの DMG で「アプリケーション」のアプリを置き換え、[初回起動](#初回起動--gatekeeper-で許可する)の手順をもう一度行います。
  ゴミ箱の監視を使っていて、その後メニューバーに Sentinel のアイコンが見当たらない場合は、設定でゴミ箱の監視（と定期スキャンの通知）をオフにしてからオンにします（#50）。
- **削除**: 設定でゴミ箱の監視・定期スキャンの通知をオフにして（ログイン項目を解除）から、App Cleaner をゴミ箱に入れます。

### CLI のインストール

**Homebrew（推奨 — 許可の手順は不要）**

```sh
brew install dallisoft/tap/appcleaner
appcleaner version
```

お使いの Mac でソースからビルドするため（Swift 6 を含む Command Line Tools または Xcode が必要）、Gatekeeper にブロックされません。更新は `brew upgrade appcleaner` です。

**tar.gz（CLI 単体）**

```sh
cd ~/Downloads
tar -xzf appcleaner-<バージョン>-macos-arm64.tar.gz
xattr -dr com.apple.quarantine appcleaner-<バージョン>-macos-arm64   # このフォルダの隔離属性だけを削除
./appcleaner-<バージョン>-macos-arm64/appcleaner version
```

隔離属性を取り除かないと、「“appcleaner”は開かれていません」と表示されて実行されません。ブラウザではなく `curl -LO` でダウンロードしたファイルには隔離属性が付きません。
アプリをインストールしている場合は `"/Applications/App Cleaner.app/Contents/Helpers/appcleaner"` をそのまま使うこともできます。

### リリースの作成（管理者）

`v*` タグをプッシュすると、GitHub Actions（`.github/workflows/release.yml`）が macOS arm64 ランナーでビルドしてアップロードします。テストは PR の前にローカルで
`./scripts/test.sh` を実行します（CI はありません）。ローカルでは `VERSION=0.1.1 ./scripts/package-release.sh` を実行します。

## CLI

```sh
appcleaner scan "/Applications/Foo.app"          # 検査のみ（何も削除しない）
appcleaner remove Foo --dry-run                  # 整理計画を JSON で出力
appcleaner remove Foo                            # 確認後、ゴミ箱／保留フォルダへ移動
appcleaner orphans --min-confidence medium       # 孤立ファイルをスキャン
appcleaner orphans clean --dry-run               # 孤立ファイルの整理計画（既定: 信頼度「高」かつユーザデータ以外）
appcleaner packages                              # npm・cargo・pipx・uv でインストールした CLI ツール＋同じ名前のデータ
appcleaner packages remove <名前> --dry-run      # CLI ツールの削除計画（--with-data: データも）
appcleaner packages caches clean --dry-run       # パッケージマネージャのダウンロードキャッシュの整理計画
appcleaner history                               # 削除履歴
appcleaner restore <セッション ID>                # 元に戻す
```

`.app` バンドル内の `Contents/Helpers/appcleaner` が CLI です。

出力言語（韓国語・英語・日本語）は `--lang <ko|en|ja>` → `APPCLEANER_LANG` → `LC_ALL`・`LC_MESSAGES`・`LANG` → システムの言語の順に決まり、対応していない言語では英語で表示します。`--json` の出力は言語によらず同じです。

## 安全方針

- 完全には削除しません。ユーザのファイルはゴミ箱へ、root 所有のファイルは保留フォルダ（`/Library/Application Support/AppCleaner/Holding`）へ移動し、削除履歴から元に戻せます。
- 信頼度の低い項目、他のアプリと共有されている項目、ユーザデータは既定では選択されません。iCloud のデータ、デバイスのバックアップ、`~/.ssh` などは選択自体ができません。
- 管理者権限が必要な操作は、バンドル内の固定スクリプト（`privileged-op.sh`、ハッシュ検証済み）のみを実行し、権限昇格した側でパスを再検証します。
  特権ヘルパー（LaunchDaemon、XPC、ファイルディスクリプタ基準の移動）も含まれていますが、Team ID で署名したビルドでのみ動作します。公式リリースは ad-hoc 署名のため管理者パスワード方式を使い、
  ご自身の Developer ID でビルドした場合は設定からヘルパーをインストールできます（[docs/development.md](docs/development.md) の「권한 헬퍼」の節）。

## 現在の状況（v0.3.x）

plan.md の Phase 1a・1b・2・3 の範囲です。残りの作業は [`backlog` ラベルの Issue](https://github.com/dallisoft/app-cleaner/issues?q=is%3Aissue+is%3Aopen+label%3Abacklog) で管理しています。

- Phase 3: ゴミ箱の監視・定期的な孤立ファイルスキャン（Sentinel、#18）、権限ヘルパー（#17 — 公式リリースでは使用しない）
- 配布: **公証・Developer ID 署名は行いません**（上記の[初回起動](#初回起動--gatekeeper-で許可する)）。Sparkle による自動アップデートの検討（#48）、Homebrew CLI tap（#15）、ルールデータ署名鍵の更新（#20）
- VM・実機での QA マトリクス（#21）、GUI の未対応事項（#22）
- 多言語対応: GUI・CLI ともに韓国語・英語・日本語に対応（その他の言語では英語）。日本語画面の確認と翻訳の校正は #27
- パッケージマネージャ（npm・cargo・pipx・uv）でインストールした CLI ツール・データ・キャッシュの整理は CLI のみ — [docs/packages.md](docs/packages.md)（#39）

## フィードバック

- バグ報告や機能の提案は [Issues](https://github.com/dallisoft/app-cleaner/issues) にお寄せください。macOS のバージョンと App Cleaner のバージョン（`appcleaner version`）を書いていただけると助かります。
- このリポジトリは**外部からのプルリクエストを受け付けていません**（PR はメンテナのみ作成できます）。修正の提案は Issue でお知らせください。
  MIT ライセンスの条件（著作権表示とライセンス文の保持）の範囲で、フォークして自由に改変できます。

## ライセンス

[MIT](LICENSE) © 2026 Cha Sangkug (dallisoft)。アプリ・CLI の配布物にも `LICENSE` が含まれています（アプリでは `Contents/Resources/LICENSE`）。

サードパーティ: アプリ・CLI に含まれる Homebrew Cask の整理ルールデータ（`homebrew-casks.json`）は Homebrew Cask のメタデータから抽出したもので、BSD 2-Clause ライセンスに従います — [告知文](Sources/CleanerCore/Resources/RuleData/NOTICE-homebrew-cask.txt)。
