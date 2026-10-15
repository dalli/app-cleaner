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

[Releases](https://github.com/dallisoft/app-cleaner/releases) からダウンロードします。

- `AppCleaner-<バージョン>-macos-arm64.zip` — アプリ（CLI は `Contents/Helpers/appcleaner`）
- `appcleaner-<バージョン>-macos-arm64.tar.gz` — CLI 単体（実行ファイルと同じ場所に `AppCleaner_CleanerCore.bundle` を置いてください）

ad-hoc 署名・未公証のビルドのため、初回起動時に Gatekeeper にブロックされた場合は Finder で右クリック › 開く を使ってください。
リリースは `v*` タグをプッシュすると、GitHub Actions（`.github/workflows/release.yml`）が macOS arm64 ランナーでビルド・テストしたうえでアップロードします。
ローカルでは `VERSION=0.1.1 ./scripts/package-release.sh` を実行します。

## CLI

```sh
appcleaner scan "/Applications/Foo.app"          # 検査のみ（何も削除しない）
appcleaner remove Foo --dry-run                  # 整理計画を JSON で出力
appcleaner remove Foo                            # 確認後、ゴミ箱／保留フォルダへ移動
appcleaner orphans --min-confidence medium       # 孤立ファイルをスキャン
appcleaner orphans clean --dry-run               # 孤立ファイルの整理計画（既定: 信頼度「高」かつユーザデータ以外）
appcleaner history                               # 削除履歴
appcleaner restore <セッション ID>                # 元に戻す
```

`.app` バンドル内の `Contents/Helpers/appcleaner` が CLI です。

出力言語（韓国語・英語・日本語）は `--lang <ko|en|ja>` → `APPCLEANER_LANG` → `LC_ALL`・`LC_MESSAGES`・`LANG` → システムの言語の順に決まり、対応していない言語では英語で表示します。`--json` の出力は言語によらず同じです。

## 安全方針

- 完全には削除しません。ユーザのファイルはゴミ箱へ、root 所有のファイルは保留フォルダ（`/Library/Application Support/AppCleaner/Holding`）へ移動し、削除履歴から元に戻せます。
- 信頼度の低い項目、他のアプリと共有されている項目、ユーザデータは既定では選択されません。iCloud のデータ、デバイスのバックアップ、`~/.ssh` などは選択自体ができません。
- 管理者権限が必要な操作は、バンドル内の固定スクリプト（`privileged-op.sh`、ハッシュ検証済み）のみを実行し、権限昇格した側でパスを再検証します。
  設定で特権ヘルパー（LaunchDaemon）をインストールすると、コード署名を確認できた App だけが XPC で依頼でき、ヘルパーがファイルディスクリプタ基準でパスを検証して移動します（Developer ID 署名 #19 の後に利用可能）。

## 現在の状況（v0.1.x — MVP）

plan.md の Phase 1a・1b・2 の範囲です。残りの作業は [`backlog` ラベルの Issue](https://github.com/dallisoft/app-cleaner/issues?q=is%3Aissue+is%3Aopen+label%3Abacklog) で管理しています。

- Phase 3: 管理者権限の経路を権限ヘルパーに置き換え — 現行経路の TOCTOU の制約を解消（#17）、ゴミ箱の監視・定期的な孤立ファイルスキャン（#18）
- Phase 4: Developer ID 署名・公証、Sparkle（#19）、Homebrew tap・cask（#15, #16）、ルールデータ署名鍵の更新（#20）
- VM・実機での QA マトリクス（#21）、GUI の未対応事項（#22）
- 多言語対応: GUI・CLI ともに韓国語・英語・日本語に対応（その他の言語では英語）。日本語画面の確認と翻訳の校正は #27
