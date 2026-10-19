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

> **App Cleaner는 Apple 공증(notarization)을 받지 않습니다.** 소스를 공개하고, 이 저장소의 GitHub Actions가 그 소스로 빌드한
> ad-hoc 서명 바이너리를 [Releases](https://github.com/dallisoft/app-cleaner/releases)에 올립니다
> ([`release.yml`](.github/workflows/release.yml), 빌드 기록은 Actions 탭).
> 그래서 처음 실행할 때 macOS Gatekeeper가 막습니다. 아래 [처음 실행](#처음-실행--gatekeeper-허용)을 따라 **한 번** 허용하면 됩니다.
> 바이너리를 쓰고 싶지 않으면 [빌드](#빌드)처럼 직접 빌드하거나, CLI는 Homebrew(소스 빌드)로 설치하세요.

### 받을 파일

| 파일 | 내용 |
|---|---|
| `AppCleaner-<버전>-macos-arm64.dmg` | **앱 (권장)** — 열어서 App Cleaner를 Applications로 끌어 놓기 |
| `AppCleaner-<버전>-macos-arm64.zip` | 앱 (DMG와 같음) |
| `appcleaner-<버전>-macos-arm64.tar.gz` | CLI 단독 (실행 파일 옆의 `AppCleaner_CleanerCore.bundle`을 함께 둘 것) |
| `SHA256SUMS.txt` | 위 파일들의 SHA-256 |

받은 파일이 릴리즈에 올라간 것과 같은지 확인한다 (권장):

```sh
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt --ignore-missing   # 받은 파일마다 OK
```

### 설치

1. DMG를 열고 **App Cleaner를 Applications 폴더로 끌어 놓는다** (zip은 풀어서 나온 앱을 Applications로 옮긴다).
2. 꼭 **Applications로 옮긴 뒤** 실행한다. DMG 창이나 다운로드 폴더에서 바로 열면 macOS가 앱을 임시 위치(App Translocation)로 옮겨 실행한다.

### 처음 실행 — Gatekeeper 허용

처음 열면 아래 창이 뜨고 실행되지 않는다. 정상이다 (공증하지 않은 앱이라서).

> **‘App Cleaner’을(를) 열지 않음**
>
> Apple은 ‘App Cleaner’에 사용자의 Mac에 손상을 입히거나 사용자의 개인정보에 침입할 수 있는 악성 코드가 없음을 확인할 수 없습니다.
>
> 버튼: 도움말 · 휴지통으로 이동 · 완료

**완료**를 누른 뒤(휴지통으로 이동 ✗) 다음 둘 중 하나로 허용한다.

**방법 1 — 시스템 설정 (터미널 없이)**

1. **시스템 설정 › 개인정보 보호 및 보안**을 열고 맨 아래 **보안** 영역까지 내린다.
2. "Mac을 보호하기 위해 ‘App Cleaner’을(를) 차단했습니다." 옆의 **그래도 열기**를 누른다.
   이 버튼은 앱을 열려고 한 뒤 약 1시간 동안만 보인다 — 없으면 앱을 한 번 더 열어 본 뒤 다시 확인한다.
3. 암호 또는 Touch ID로 확인한다.
4. 확인 창이 한 번 더 뜨면 **그래도 열기**를 누른다. 이후로는 바로 열린다.

**방법 2 — 터미널 (한 줄)**

```sh
xattr -dr com.apple.quarantine "/Applications/App Cleaner.app"
open "/Applications/App Cleaner.app"
```

`xattr -dr`은 인터넷에서 받은 파일에 붙는 "격리(quarantine)" 표시를 **이 앱에서만** 지운다. 앱의 서명이나 Mac의 Gatekeeper 설정은
바꾸지 않는다. 보통 `sudo`는 필요 없다. 허용 창 없이 바로 열리고, 임시 위치(App Translocation)에서 실행되는 일도 없다.

알아 둘 것

- 어느 방법이든 허용은 **앱 안의 Sentinel(메뉴 막대 휴지통 감시)과 CLI(`Contents/Helpers/appcleaner`)에도 함께 적용**된다.
- macOS 14(Sonoma)에서는 Finder에서 앱을 Control-클릭 › **열기** › **열기**로도 허용된다. macOS 15부터는 이 방법이 막혀 위 방법을 써야 한다.
- 허용은 그 버전(코드)에만 적용된다. **새 버전으로 업데이트하면 다시 한 번 허용**해야 한다.
- "손상되었기 때문에 열 수 없습니다"가 뜨면 내려받기가 깨졌거나 압축을 푸는 과정에서 서명이 손상된 것이다.
  위 체크섬을 확인하고 다시 받아 DMG로 설치한 뒤, 그래도 같으면 방법 2를 쓴다.

### 처음 실행한 뒤

- 첫 화면(온보딩)에서 안내하는 **전체 디스크 접근**을 App Cleaner에 허용한다 (시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근 권한).
  다른 앱의 컨테이너를 읽는 데 필요하고, 휴지통 감시(Sentinel)도 이 권한을 함께 쓴다 — Sentinel은 목록에 따로 나오지 않는다.
- 설정 › 휴지통 감시 또는 정기 스캔 알림을 켜면 Sentinel이 로그인 항목으로 등록된다. macOS가 "앱 백그라운드 활동" 알림과
  "‘App Cleaner Sentinel’ 알림" 허용 요청을 띄운다.
- 관리자 작업(시스템 폴더 항목 정리·복원)은 관리자 암호를 묻는다. 권한 헬퍼는 Developer ID 서명 빌드에서만 동작하므로 공식 릴리즈에서는 쓰지 않는다.

### 업데이트·제거

- **업데이트**: 새 버전 DMG로 Applications의 앱을 바꾼 뒤 [처음 실행](#처음-실행--gatekeeper-허용)을 다시 한다.
  휴지통 감시를 쓰고 있었는데 메뉴 막대에 Sentinel 아이콘이 보이지 않으면 설정에서 휴지통 감시(와 정기 스캔 알림)를 끄고 다시 켠다 (#50).
- **제거**: 설정에서 휴지통 감시·정기 스캔 알림을 끈 뒤(로그인 항목 해제) App Cleaner를 휴지통으로 옮긴다.

### CLI 설치

**Homebrew (권장 — 허용 절차 없음)**

```sh
brew install dallisoft/tap/appcleaner
appcleaner version
```

Mac에서 소스를 빌드하므로(Swift 6이 든 Command Line Tools 또는 Xcode 필요) Gatekeeper에 막히지 않는다. 업데이트는 `brew upgrade appcleaner`.

**tar.gz (CLI 단독)**

```sh
cd ~/Downloads
tar -xzf appcleaner-<버전>-macos-arm64.tar.gz
xattr -dr com.apple.quarantine appcleaner-<버전>-macos-arm64   # 이 폴더의 격리 표시만 지움
./appcleaner-<버전>-macos-arm64/appcleaner version
```

격리 표시를 지우지 않으면 "‘appcleaner’을(를) 열지 않음" 창과 함께 실행되지 않는다. 브라우저 대신 `curl -LO`로 받은 파일에는 격리 표시가 붙지 않는다.
앱을 설치했다면 `"/Applications/App Cleaner.app/Contents/Helpers/appcleaner"`를 그대로 써도 된다.

### 릴리즈 만들기 (관리자)

`v*` 태그를 푸시하면 GitHub Actions(`.github/workflows/release.yml`)가 macOS arm64 러너에서 빌드해 올린다. 테스트는 PR 전에 로컬에서
`./scripts/test.sh`로 돌린다 (CI 없음). 로컬에서는 `VERSION=0.1.1 ./scripts/package-release.sh`.

## CLI

```sh
appcleaner scan "/Applications/Foo.app"          # 검사만 (아무것도 지우지 않음)
appcleaner remove Foo --dry-run                  # 정리 계획 JSON
appcleaner remove Foo                            # 확인 후 휴지통/보류 폴더로 이동
appcleaner orphans --min-confidence medium       # 고아 잔여물 스캔
appcleaner orphans clean --dry-run               # 고아 정리 계획 (기본: 높음 + 사용자 데이터 아님)
appcleaner packages                              # npm·bun·pnpm·cargo·pipx·uv·설치 스크립트로 설치한 CLI 도구 + 데이터
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
  권한 헬퍼(LaunchDaemon, XPC·fd 기반 이동)도 들어 있지만 Team ID로 서명한 빌드에서만 동작한다. 공식 릴리즈는 ad-hoc 서명이라 관리자 암호 방식을 쓰고,
  자기 Developer ID로 직접 빌드하면 설정에서 헬퍼를 설치할 수 있다 ([docs/development.md](docs/development.md) "권한 헬퍼").

## 현재 상태 (v0.3.x)

plan.md의 Phase 1a·1b·2·3 범위. 남은 작업은 [`backlog` 라벨 이슈](https://github.com/dallisoft/app-cleaner/issues?q=is%3Aissue+is%3Aopen+label%3Abacklog)로 관리한다.

- Phase 3: 휴지통 감시·정기 고아 스캔 (Sentinel, #18), 권한 헬퍼 (#17 — 공식 릴리즈에서는 쓰지 않음)
- 배포: **공증·Developer ID 서명은 하지 않는다** (위 [처음 실행](#처음-실행--gatekeeper-허용)). Sparkle 자동 업데이트 검토 (#48), Homebrew CLI tap (#15), 규칙 데이터 서명 키 교체 (#20)
- VM·실기기 QA 매트릭스 (#21), GUI 미비점 (#22)
- 다국어: GUI·CLI 모두 한국어·영어·일본어 지원 (그 밖의 언어는 영어). 일본어 화면 확인·번역 검수는 #27
- 패키지 매니저(npm·bun·pnpm·cargo·pipx·uv)와 설치 스크립트(`curl … | sh`)로 설치한 CLI 도구·데이터·캐시 정리는 CLI만 — [docs/packages.md](docs/packages.md) (#39)
  - 설치 스크립트로 설치한 도구는 설치 기록이 없어, 알려진 도구는 규칙 데이터로 정확히 잡고 그 외 `~/.local/bin`의 실행 파일은 이름 추정으로 **낮음·기본 미선택**으로 보여 줍니다
  - bun·pnpm은 잠금 파일이 따로 있어 파일을 옮겨도 다음 전역 설치 때 되살아납니다. 그래서 옮기지 않고 `bun remove -g` 안내만 합니다 (Homebrew처럼 읽기 전용)

## 기여·문의

- 버그 제보·기능 제안은 [Issues](https://github.com/dallisoft/app-cleaner/issues)로 보내 주세요. 사용 중인 macOS 버전과 App Cleaner 버전(`appcleaner version`)을 함께 적어 주시면 좋습니다.
- 이 저장소는 **외부 Pull Request를 받지 않습니다** (PR은 관리자만 만들 수 있게 설정되어 있습니다). 고칠 점은 이슈로 알려 주세요.
  MIT 라이선스 조건(저작권·라이선스 표시 유지) 안에서 포크해 고쳐 쓰는 것은 자유입니다.

## 라이선스

[MIT](LICENSE) © 2026 Cha Sangkug (dallisoft). 앱·CLI 배포물에도 `LICENSE`가 들어 있다 (앱은 `Contents/Resources/LICENSE`).

서드파티: 앱·CLI에 포함된 Homebrew Cask 정리 규칙 데이터(`homebrew-casks.json`)는 Homebrew Cask 메타데이터에서 추출했으며 BSD 2-Clause 라이선스를 따른다 — [고지문](Sources/CleanerCore/Resources/RuleData/NOTICE-homebrew-cask.txt).
