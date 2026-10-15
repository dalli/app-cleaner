#!/bin/sh
# App Cleaner.app 번들을 만든다 (Command Line Tools만으로, Xcode 프로젝트 없이).
#
#   ./scripts/build-app.sh            # release 빌드 → dist/App Cleaner.app
#   CONFIG=debug ./scripts/build-app.sh
#   ARCH=arm64 ./scripts/build-app.sh  # 대상 아키텍처 (기본 arm64 — Apple Silicon)
#
# 결과: dist/App Cleaner.app
#   Contents/MacOS/AppCleanerGUI        GUI 실행 파일
#   Contents/Helpers/appcleaner         CLI
#   Contents/Library/LoginItems/App Cleaner Sentinel.app   메뉴 막대 Sentinel (SMAppService.loginItem — ui-ux.md S10)
#   Contents/Resources/*.bundle         SwiftPM 리소스 번들 (Bundle.module이 resourceURL에서 찾는다)
#                                        AppCleaner_CleanerCore.bundle/Localization — 엔진·CLI 번역 (ko/en/ja)
#   Contents/Resources/<언어>.lproj      앱 이름(InfoPlist.strings) — 시스템 메뉴 언어도 이 목록을 따른다
# 서명은 ad-hoc(-s -). 배포용 Developer ID 서명·공증은 Phase 4에서 한다.
set -eu
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-arm64}"
APP_NAME="App Cleaner"
BUNDLE_ID="com.dallisoft.AppCleaner"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "==> swift build -c $CONFIG --arch $ARCH (AppCleanerGUI, appcleaner, AppCleanerSentinel)"
swift build -c "$CONFIG" --arch "$ARCH" --product AppCleanerGUI
swift build -c "$CONFIG" --arch "$ARCH" --product appcleaner
swift build -c "$CONFIG" --arch "$ARCH" --product AppCleanerSentinel
BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"

DIST="dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BIN_DIR/AppCleanerGUI" "$APP/Contents/MacOS/AppCleanerGUI"
cp "$BIN_DIR/appcleaner" "$APP/Contents/Helpers/appcleaner"

# SwiftPM 리소스 번들 전부 (AppCleaner_AppCleanerGUI.bundle, AppCleaner_CleanerCore.bundle …)
found_bundle=0
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP/Contents/Resources/"
  found_bundle=1
done
if [ "$found_bundle" -eq 0 ]; then
  echo "error: no SwiftPM resource bundles found in $BIN_DIR" >&2
  exit 1
fi

# 지원 언어 (CleanerCore `AppLanguage`와 같게). 시스템 메뉴(종료, 숨기기 …)도 이 언어로 나오도록 lproj를 두고,
# 앱 이름은 InfoPlist.strings로 언어마다 지정한다. 지원하지 않는 언어 사용자는 개발 지역(en)으로 본다.
LANGUAGES="ko en ja"
for lang in $LANGUAGES; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  cat > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings" <<STRINGS
"CFBundleName" = "$APP_NAME";
"CFBundleDisplayName" = "$APP_NAME";
STRINGS
done
for lang in $LANGUAGES; do
  if [ ! -d "$APP/Contents/Resources/AppCleaner_CleanerCore.bundle/Localization/$lang.lproj" ] \
     && [ ! -d "$APP/Contents/Resources/AppCleaner_CleanerCore.bundle/Contents/Resources/Localization/$lang.lproj" ]; then
    echo "error: CleanerCore 번역($lang.lproj)이 리소스 번들에 없습니다" >&2
    exit 1
  fi
done

# Sentinel (메뉴 막대 상주, Dock 아이콘 없음). 번역·규칙 데이터를 읽도록 CleanerCore 리소스 번들을 함께 넣는다.
SENTINEL_ID="$BUNDLE_ID.Sentinel"
SENTINEL="$APP/Contents/Library/LoginItems/$APP_NAME Sentinel.app"
mkdir -p "$SENTINEL/Contents/MacOS" "$SENTINEL/Contents/Resources"
cp "$BIN_DIR/AppCleanerSentinel" "$SENTINEL/Contents/MacOS/AppCleanerSentinel"
cp -R "$APP/Contents/Resources/AppCleaner_CleanerCore.bundle" "$SENTINEL/Contents/Resources/"
cat > "$SENTINEL/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>AppCleanerSentinel</string>
  <key>CFBundleIdentifier</key>
  <string>$SENTINEL_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME Sentinel</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME Sentinel</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$SENTINEL/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>ko</string>
    <string>en</string>
    <string>ja</string>
  </array>
  <key>CFBundleExecutable</key>
  <string>AppCleanerGUI</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID.sentinel</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>com.dallisoft.appcleaner</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Application</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.apple.application-bundle</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
# 안쪽 번들(Sentinel)을 먼저 서명한 뒤 바깥 앱을 서명한다
codesign --force -s - "$SENTINEL"
codesign --force --deep -s - "$APP"

echo "==> $(cd "$DIST" && pwd)/$APP_NAME.app"
