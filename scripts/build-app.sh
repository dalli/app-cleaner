#!/bin/sh
# App Cleaner.app 번들을 만든다 (Command Line Tools만으로, Xcode 프로젝트 없이).
#
#   ./scripts/build-app.sh            # release 빌드 → dist/App Cleaner.app
#   CONFIG=debug ./scripts/build-app.sh
#
# 결과: dist/App Cleaner.app
#   Contents/MacOS/AppCleanerGUI        GUI 실행 파일
#   Contents/Helpers/appcleaner         CLI
#   Contents/Resources/*.bundle         SwiftPM 리소스 번들 (Bundle.module이 resourceURL에서 찾는다)
# 서명은 ad-hoc(-s -). 배포용 Developer ID 서명·공증은 Phase 4에서 한다.
set -eu
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="App Cleaner"
BUNDLE_ID="com.dallisoft.AppCleaner"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "==> swift build -c $CONFIG (AppCleanerGUI, appcleaner)"
swift build -c "$CONFIG" --product AppCleanerGUI
swift build -c "$CONFIG" --product appcleaner
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

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

# 시스템 메뉴(종료, 숨기기 …)도 한국어/영어로 나오도록 빈 lproj를 둔다
mkdir -p "$APP/Contents/Resources/ko.lproj" "$APP/Contents/Resources/en.lproj"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ko</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>ko</string>
    <string>en</string>
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
codesign --force --deep -s - "$APP"

echo "==> $(cd "$DIST" && pwd)/$APP_NAME.app"
