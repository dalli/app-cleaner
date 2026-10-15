#!/bin/sh
# Homebrew formula의 url·sha256을 릴리즈 태그의 소스 tarball로 고친다.
#
#   ./scripts/update-homebrew-formula.sh v0.2.1                          # packaging/homebrew/appcleaner.rb
#   ./scripts/update-homebrew-formula.sh v0.2.1 ../homebrew-tap/Formula/appcleaner.rb
#
# tarball: https://github.com/<REPO>/archive/refs/tags/<태그>.tar.gz (REPO 기본값 dallisoft/app-cleaner)
# 버전은 Homebrew가 url의 태그에서 읽으므로 따로 쓰지 않는다.
# release.yml이 v* 태그 푸시 때 tap(dallisoft/homebrew-tap)의 Formula/appcleaner.rb에 대해 실행한다.
set -eu

TAG="${1:?태그를 지정하세요 (예: v0.2.1)}"
FORMULA="${2:-$(dirname "$0")/../packaging/homebrew/appcleaner.rb}"
REPO="${REPO:-dallisoft/app-cleaner}"

if ! printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  echo "error: 태그 형식이 아닙니다: $TAG (예: v0.2.1)" >&2
  exit 1
fi
if [ ! -f "$FORMULA" ]; then
  echo "error: formula 파일이 없습니다: $FORMULA" >&2
  exit 1
fi
if [ "$(grep -c '^  url "' "$FORMULA")" -ne 1 ] || [ "$(grep -c '^  sha256 "' "$FORMULA")" -ne 1 ]; then
  echo "error: $FORMULA 에서 url·sha256 줄을 하나씩 찾지 못했습니다" >&2
  exit 1
fi

URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> $URL"
curl -fsSL --retry 5 --retry-delay 5 -o "$WORK/source.tar.gz" "$URL"
if command -v shasum >/dev/null 2>&1; then
  SHA256="$(shasum -a 256 "$WORK/source.tar.gz" | awk '{print $1}')"
else
  SHA256="$(sha256sum "$WORK/source.tar.gz" | awk '{print $1}')"
fi
echo "    sha256 $SHA256"

# stable의 url·sha256 줄(들여쓰기 2칸, 위에서 하나씩인 것을 확인)만 바꾼다. head 줄은 그대로 둔다.
sed -e "s|^  url \".*\"\$|  url \"$URL\"|" \
    -e "s|^  sha256 \".*\"\$|  sha256 \"$SHA256\"|" \
    "$FORMULA" > "$WORK/formula.rb"
cat "$WORK/formula.rb" > "$FORMULA"
echo "==> $FORMULA"
