**한국어** | [English](README.en.md) | [日本語](README.ja.md)

# App Cleaner (가칭)

macOS 앱을 잔여물까지 **안전하게, 되돌릴 수 있게** 제거하는 도구. 이미 지운 앱의 고아 잔여물도 따로 찾아 정리한다.

- 설계: [docs/plan.md](docs/plan.md), [docs/ui-ux.md](docs/ui-ux.md)
- 개발: [docs/development.md](docs/development.md)

요구 사항: macOS 14 이상, Swift 6 (Command Line Tools 또는 Xcode).

## 빌드

```sh
./scripts/build-app.sh                 # dist/App Cleaner.app (ad-hoc 서명)
open "dist/App Cleaner.app"            # 실제 엔진
open -n "dist/App Cleaner.app" --args --demo   # 가짜 데이터로 화면 확인
./scripts/test.sh                      # 테스트
```

## 설치 (Apple Silicon)

[Releases](https://github.com/dallisoft/app-cleaner/releases)에서 받는다.

- `AppCleaner-<버전>-macos-arm64.zip` — 앱 (CLI는 `Contents/Helpers/appcleaner`)
- `appcleaner-<버전>-macos-arm64.tar.gz` — CLI 단독 (실행 파일 옆의 `AppCleaner_CleanerCore.bundle`을 함께 둘 것)

ad-hoc 서명·미공증 빌드라 처음 실행 시 Gatekeeper가 막으면 Finder에서 우클릭 › 열기를 쓴다.
릴리즈는 `v*` 태그를 푸시하면 GitHub Actions(`.github/workflows/release.yml`)가 macOS arm64 러너에서 빌드·테스트 후 올린다.
로컬에서는 `VERSION=0.1.1 ./scripts/package-release.sh`.

## CLI

```sh
appcleaner scan "/Applications/Foo.app"          # 검사만 (아무것도 지우지 않음)
appcleaner remove Foo --dry-run                  # 정리 계획 JSON
appcleaner remove Foo                            # 확인 후 휴지통/보류 폴더로 이동
appcleaner orphans --min-confidence medium       # 고아 잔여물 스캔
appcleaner orphans clean --dry-run               # 고아 정리 계획 (기본: 높음 + 사용자 데이터 아님)
appcleaner packages                              # npm·cargo·pipx·uv로 설치한 CLI 도구 + 이름이 같은 데이터
appcleaner packages remove <이름> --dry-run      # CLI 도구 제거 계획 (--with-data: 데이터도)
appcleaner packages caches clean --dry-run       # 패키지 매니저 다운로드 캐시 정리 계획
appcleaner history                               # 삭제 기록
appcleaner restore <세션 ID>                     # 되돌리기
```

`.app` 번들 안의 `Contents/Helpers/appcleaner`가 CLI다.

출력 언어(한국어·영어·일본어)는 `--lang <ko|en|ja>` → `APPCLEANER_LANG` → `LC_ALL`·`LC_MESSAGES`·`LANG` → 시스템 언어 순으로 정하고, 지원하지 않는 언어면 영어로 표시한다. `--json` 출력은 언어와 관계없이 같다.

## 안전 원칙

- 영구 삭제하지 않는다: 사용자 파일은 휴지통, root 소유 파일은 보류 폴더(`/Library/Application Support/AppCleaner/Holding`)로 옮기고 삭제 기록으로 되돌린다.
- 신뢰도 낮음·다른 앱과 공유·사용자 데이터는 기본 선택하지 않는다. iCloud 데이터·기기 백업·`~/.ssh` 등은 선택할 수 없다.
- 관리자 작업은 번들의 고정 스크립트(`privileged-op.sh`, 해시 확인)만 실행하며 권한 상승된 쪽에서 경로를 다시 검증한다.

## 현재 상태 (v0.1.x — MVP)

plan.md의 Phase 1a·1b·2 범위. 남은 작업은 [`backlog` 라벨 이슈](https://github.com/dallisoft/app-cleaner/issues?q=is%3Aissue+is%3Aopen+label%3Abacklog)로 관리한다.

- Phase 3: 권한 헬퍼로 관리자 경로 교체 — 현재 경로의 TOCTOU 제한 해소 (#17), 휴지통 감시·정기 고아 스캔 (#18)
- Phase 4: Developer ID 서명·공증, Sparkle (#19), Homebrew tap·cask (#15, #16), 규칙 데이터 서명 키 교체 (#20)
- VM·실기기 QA 매트릭스 (#21), GUI 미비점 (#22)
- 다국어: GUI·CLI 모두 한국어·영어·일본어 지원 (그 밖의 언어는 영어). 일본어 화면 확인·번역 검수는 #27
- 패키지 매니저(npm·cargo·pipx·uv)로 설치한 CLI 도구·데이터·캐시 정리는 CLI만 — [docs/packages.md](docs/packages.md) (#39)
