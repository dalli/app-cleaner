#!/bin/sh
# 릴리즈 산출물을 만든다 (Apple Silicon / arm64).
#
#   VERSION=0.1.1 ./scripts/package-release.sh
#
# 결과 (dist/):
#   AppCleaner-<버전>-macos-arm64.zip       App Cleaner.app (GUI + Contents/Helpers/appcleaner)
#   appcleaner-<버전>-macos-arm64.tar.gz    CLI 단독 (실행 파일 + 리소스 번들: 규칙 데이터·관리자 스크립트·번역)
#   SHA256SUMS.txt
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:?VERSION을 지정하세요 (예: 0.1.1)}"
ARCH=arm64
DIST=dist
APP="$DIST/App Cleaner.app"

ARCH="$ARCH" VERSION="$VERSION" ./scripts/build-app.sh

# 아키텍처 확인 — arm64가 아니면 실패
for bin in "$APP/Contents/MacOS/AppCleanerGUI" "$APP/Contents/MacOS/AppCleanerHelper" "$APP/Contents/Helpers/appcleaner"; do
  archs="$(lipo -archs "$bin")"
  if [ "$archs" != "arm64" ]; then
    echo "error: $bin 아키텍처가 arm64가 아닙니다: $archs" >&2
    exit 1
  fi
done

APP_ZIP="AppCleaner-$VERSION-macos-$ARCH.zip"
CLI_TGZ="appcleaner-$VERSION-macos-$ARCH.tar.gz"
rm -f "$DIST/$APP_ZIP" "$DIST/$CLI_TGZ" "$DIST/SHA256SUMS.txt"

echo "==> $APP_ZIP"
(cd "$DIST" && ditto -c -k --keepParent "App Cleaner.app" "$APP_ZIP")

echo "==> $CLI_TGZ"
STAGE="$DIST/appcleaner-$VERSION-macos-$ARCH"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$APP/Contents/Helpers/appcleaner" "$STAGE/appcleaner"
# CLI는 실행 파일 옆의 리소스 번들에서 규칙 데이터·관리자 스크립트·번역(Localization/<언어>.lproj)을 찾는다
cp -R "$APP/Contents/Resources/AppCleaner_CleanerCore.bundle" "$STAGE/"
if ! find "$STAGE/AppCleaner_CleanerCore.bundle" -path '*/Localization/ja.lproj/CLI.strings' | grep -q .; then
  echo "error: CLI 번역이 리소스 번들에 없습니다" >&2
  exit 1
fi
cp README.md "$STAGE/"
tar -C "$DIST" -czf "$DIST/$CLI_TGZ" "$(basename "$STAGE")"
rm -rf "$STAGE"

(cd "$DIST" && shasum -a 256 "$APP_ZIP" "$CLI_TGZ" > SHA256SUMS.txt)
cat "$DIST/SHA256SUMS.txt"
