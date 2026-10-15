# 개발 가이드

## 빌드·테스트

```sh
swift build
./scripts/test.sh            # Swift Testing (Command Line Tools 환경에서 매크로 플러그인 경로를 지정)
./scripts/test.sh --filter OrphanScannerTests
APPCLEANER_PERF=1 ./scripts/test.sh --filter slackLikeEndToEnd   # 성능 목표(앱 1개 2초) 단독 확인
```

Xcode 없이 Command Line Tools만으로 빌드·테스트한다. XCTest는 사용하지 않고 Swift Testing(`import Testing`)만 쓴다.

## 패키지 구조

| 타깃 | 역할 |
|---|---|
| `CleanerCore` | 엔진 (UI 무관). GUI·CLI가 공유 |
| `CleanerTestSupport` | 픽스처(`Fixture`), `StubCommandRunner`, `StubSignatureReader` |
| `appcleaner` | CLI |
| `AppCleanerHelper` | 권한 헬퍼 (LaunchDaemon). 리스너만 열고 처리는 `CleanerCore/Privileged` ("권한 헬퍼") |
| `AppCleanerGUI` | SwiftUI 앱 (`scripts/build-app.sh`로 `.app` 번들 생성) |

### CleanerCore 폴더 소유

| 폴더 | 내용 | plan.md |
|---|---|---|
| `Models/` | 공용 모델 (Candidate, AppIdentity, Plan, Journal …) | — |
| `Environment/` | `SystemPaths`(루트 주입), `CommandRunning`, `BundleInfo`, 코드서명 | 8.2 |
| `Contracts/` | 구성 요소 프로토콜, `CleanerEngine` 파사드, `RuleData` 모델 | 8.2 |
| `Identity/`, `Discovery/`, `Selection/`, `Scanning/` | 앱 제거 탐지 | 4.1~4.3 |
| `Safety/`, `Preflight/`, `Mover/`, `Journal/`, `Execution/` | 정리 실행·기록·복원 | 4.4, 5, 6 |
| `Privileged/` | 권한 헬퍼: fd 기반 이동(`SecureFileOperations`), 명령 검증(`PrivilegedCommandProcessor`), XPC·서명 요구사항, `SMAppService` 설치 | 5.3 |
| `Inventory/`, `Orphan/`, `RuleUpdate/` | 인벤토리·고아 스캔·규칙 데이터 서명 | 4.5, 4.6 |
| `Engine/` | `LiveCleanerEngine` 조립 | 8.2 |
| `Localization/` | `AppLanguage`(언어 선택), `Translations`(엔진·CLI 번역 표 조회) | — |

## 규칙

- 엔진 코드는 `/`·`NSHomeDirectory()`를 직접 쓰지 않는다. 항상 `SystemPaths`를 주입받는다.
- 외부 명령은 `CommandRunning`으로만 실행한다 (셸 문자열 조립 금지).
- 테스트는 `Fixture`의 임시 트리 안에서만 파일을 만들고 지운다. 실제 홈·`/Library`·휴지통을 건드리는 테스트 금지.
- 공용 모델(`Models/`, `Contracts/`)을 바꿔야 하면 하위 호환되게 **추가만** 한다.
- 사용자 표시 문구는 한국어 원문을 키로 쓰고 번역 파일을 함께 고친다 (아래 "번역 추가 절차"). 내부 용어(bootout, cfprefsd 등)는 "정보원" 칸에만 (ui-ux.md 4.3).

## 번역 추가 절차 (Localization)

지원 언어는 한국어(ko)·영어(en)·일본어(ja)이고, 사용자의 선호 언어에 이 셋이 없으면 **영어**로 보여 준다.
CLT에는 `xcstringstool`이 없어 String Catalog 대신 `.strings` + `.stringsdict`를 쓴다.

### 언어 선택

| 대상 | 순서 |
|---|---|
| GUI | `Locale.preferredLanguages`(`-AppleLanguages` 포함)에서 처음 지원하는 언어 → 영어 (`AppLanguage.preferred(from:)`) |
| CLI | `--lang <ko\|en\|ja>` → `APPCLEANER_LANG` → `LC_ALL` → `LC_MESSAGES` → `LANG` → 시스템 선호 언어 → 영어 (`AppLanguage.resolve`). `LANG`이 지원하지 않는 언어(fr_FR 등)면 영어, `C`/`POSIX`는 건너뜀 |
| 엔진이 시스템에 넘기는 문구 | `AppLanguage.current` (관리자 인증 창 `with prompt`, 이름을 바꿔 복원할 때 붙이는 "(복원됨)"). CLI는 시작할 때 고른 언어로 바꾼다 |

날짜·숫자·크기는 "UI 언어 + 시스템 지역" 로케일(`AppLanguage.locale()`)로 형식화한다. `--json` 출력은 언어와 무관하다
(엔진 문구의 `text` 필드는 항상 한국어 원문이고 `key`·`args`·`parts`로 번역할 수 있다).

### 파일 위치와 키 규칙

| 문구 | 키 | 원문(ko) | 번역 |
|---|---|---|---|
| GUI 화면 | 한국어 원문 — `L("…")`, `L("파일 %lld개", n)` | 키 자체 (`ko.lproj`는 비어 있음) | `Sources/AppCleanerGUI/Resources/<언어>.lproj/Localizable.strings` |
| GUI 개수 문구 | 위와 같음 | 키 자체 | 같은 폴더 `Localizable.stringsdict` (.strings와 키가 겹치면 안 됨, 일본어는 `other`만) |
| 엔진 문구 (판정 근거·메모·실패 사유·오류) | `EngineText.Key.rawValue` | `EngineText.Key.koreanFormat` (조사 처리 포함) | `Sources/CleanerCore/Resources/Localization/<언어>.lproj/Engine.strings` |
| CLI 출력 | 한국어 원문 — `t("…")`, `UsageError("…")` | 키 자체 (사용법만 `ko.lproj/CLI.strings`의 `"usage"`) | 같은 폴더 `CLI.strings` (+ 개수 문구 `CLI.stringsdict`, 일본어는 .strings에 둠) |

- 형식 인자는 키에 `%@`(문자열)·`%lld`(정수)로 직접 쓴다. 번역에서 어순이 바뀌면 `%2$@`처럼 위치를 지정한다. 지정자 개수·종류·인자 순서가 원문과 같아야 한다.
- 엔진 문구 안에 다른 엔진 문구가 들어가면(예: "보류 폴더로 옮기지 못했습니다: <관리자 작업 사유>") 문자열로 합치지 말고 `EngineText(…, parts: [inner])`로 넘긴다. `parts`는 `args` 다음 `%@` 자리에 같은 언어로 번역되어 들어간다.
- 한국어 조사는 GUI `Josa`(받침 판단)나 엔진 `subjectParticleOnFirstArg`로만 붙인다. 이 처리는 한국어에서만 하고 다른 언어 문구에는 섞지 않는다.
- 엔진·CLI 번역은 CleanerCore 리소스 번들(`AppCleaner_CleanerCore.bundle/…/Localization`)에 있다. CLI는 실행 파일 + 이 번들만 배포하므로(Homebrew 포함) 별도 번들이 필요 없고, `Translations`가 `BundledResources`로 찾는다 (`Bundle.module` 직접 사용 금지).
- 앱 표시 이름은 `scripts/build-app.sh`가 `<언어>.lproj/InfoPlist.strings`로 만든다. `CFBundleDevelopmentRegion`은 `en`(지원하지 않는 언어의 시스템 메뉴도 영어).

### 언어 추가 (예: `de`)

1. `CleanerCore/Localization/AppLanguage.swift`에 `case de` 추가
2. `Sources/AppCleanerGUI/Resources/de.lproj/Localizable.strings`·`.stringsdict` (en 파일을 복사해 번역)
3. `Sources/CleanerCore/Resources/Localization/de.lproj/Engine.strings`·`CLI.strings` (+ 필요하면 `CLI.stringsdict`)
4. `scripts/build-app.sh`의 `LANGUAGES`에 추가, CLI 사용법(`"usage"`)의 `--lang` 값 목록 갱신
5. `./scripts/test.sh` — 아래 검사가 새 언어에도 적용되도록 테스트의 언어 목록(`AppLanguage.allCases` 기반)을 확인

### 검사 (`./scripts/test.sh`)

| 테스트 | 확인 내용 |
|---|---|
| `AppCleanerGUITests/LocalizationTests` | 소스의 모든 `L("…")` 키가 en·ja에 있음(누락·미사용 0), 지정자 순서·종류 일치, 번역에 한글 없음, 복수형 해석(en 1/2 구분, ja other), 선호 언어 fr → en, 조사가 en·ja에 붙지 않음 |
| `CleanerCoreTests/LocalizationResourceTests` | 모든 `EngineText.Key`가 en·ja `Engine.strings`에 있음, `parts` 번역·JSON 저장, 실패 사유 JSON 하위 호환, CLI 언어 선택 순서(`APPCLEANER_LANG`·`LC_*`·`LANG`) |
| `CLITests/CLILocalizationTests` | 소스의 모든 `t("…")`·`UsageError("…")` 키가 en·ja `CLI.*`에 있음, ko/en/ja 출력, `--lang`·환경 변수·영어 대체, `--json`이 언어와 무관 |

## 권한 헬퍼 (#17, plan.md 5.3)

관리자 작업(보류 폴더 이동·복원·영구 삭제, 시스템 서비스 중지·재등록, `pkgutil --forget`)은 두 경로로 실행된다.

| 경로 | 언제 | 인증 | 경쟁 조건(TOCTOU) |
|---|---|---|---|
| **권한 헬퍼** (`HelperAdminExecutor`, XPC) | 헬퍼가 등록·허용되어 있고 서명 요구사항이 맞을 때 | 등록 시 로그인 항목 승인 1회, 이후 묻지 않음 | fd 기반 이동으로 막음 |
| 대체 경로 (`AppleScriptAdminExecutor`, `privileged-op.sh`) | 헬퍼 미설치·미승인·연결 실패·서명 불일치 (예: Homebrew CLI, `swift run`, ad-hoc 빌드) | 배치마다 관리자 암호 (최대 2회) | 줄였지만 남음 ("알려진 제한") |

`FallbackAdminExecutor`가 먼저 헬퍼에 `ping`하고, 응답이 없을 때만 대체 경로로 보낸다. 작업 요청을 보낸 뒤 연결이 끊기면
결과를 알 수 없으므로 대체 경로로 다시 보내지 않고 실패(`helper-no-reply`)로 기록한다 (같은 항목을 두 번 옮기지 않게).
대체 경로를 남긴 이유: 서명되지 않은 빌드·Homebrew CLI도 지금처럼 동작해야 하고, 사용자가 헬퍼를 승인하지 않을 수 있다.

**번들 구성** (`scripts/build-app.sh`)

| 위치 | 내용 |
|---|---|
| `Contents/MacOS/AppCleanerHelper` | 헬퍼 실행 파일 (서명 식별자 `<BID>.Helper`, Hardened Runtime) |
| `Contents/Library/LaunchDaemons/<BID>.Helper.plist` | `Label`·`MachServices` = `<BID>.Helper`, `BundleProgram`, `AssociatedBundleIdentifiers` |
| `Contents/Helpers/appcleaner` | 번들 CLI (서명 식별자 `<BID>.cli`) — 헬퍼에 연결할 수 있는 두 번째 클라이언트 |

GUI 설정(S7) "관리자 헬퍼"에서 `SMAppService.daemon(plistName:)`로 등록·해제한다. 등록 후 시스템 설정 › 일반 › 로그인 항목에서
허용해야 실행된다 (앱이 그 화면을 연다). CLI에는 설치 명령이 없다 — GUI에서 설치하면 번들 CLI도 헬퍼를 쓴다.

**서명·Team ID** — 헬퍼와 앱은 각자 **자기 서명의 Team ID**로 상대 요구사항을 만든다 (설정 파일에서 읽지 않음).

- 헬퍼 → 클라이언트: `anchor apple generic and certificate leaf[subject.OU] = "<TEAM>" and (identifier "<BID>" or identifier "<BID>.cli")`
- 앱 → 헬퍼: `anchor apple generic and certificate leaf[subject.OU] = "<TEAM>" and identifier "<BID>.Helper"`
- `NSXPCConnection.setCodeSigningRequirement(_:)`는 메시지마다 audit token으로 검사한다 (PID 검증 없음).
- 빌드: `SIGN_IDENTITY="Developer ID Application: … (XXXXXXXXXX)" TEAM_ID=XXXXXXXXXX ./scripts/build-app.sh` —
  `XXXXXXXXXX`는 자리표시자. 실제 값은 #19(Developer ID 서명)에서 정한다. `TEAM_ID`를 주면 서명 후 Team ID를 확인한다.
- 기본(ad-hoc) 빌드는 Team ID가 없어 헬퍼가 **연결을 받지 않는다** → 항상 대체 경로.
- **개발 모드** `HELPER_DEV=1 ./scripts/build-app.sh`: 헬퍼를 `APPCLEANER_HELPER_DEV` 조건으로 컴파일해 Team ID 없이
  서명 식별자만 확인한다. 같은 식별자로 서명한 아무 프로그램이나 root 작업을 요청할 수 있으므로 **배포 금지**, 로컬 확인용.
- `BUNDLE_ID`를 바꾸면 헬퍼 레이블·Mach 서비스·식별자가 모두 따라 바뀐다 (`PrivilegedHelperIdentity`).

**헬퍼가 다시 검증하는 것** (`PrivilegedCommandProcessor` — 앱의 판단을 신뢰하지 않음)

- 명령은 `AdminOperation` 6종뿐 (JSON 필드별 검증, 모르는 명령 거부). 임의 셸 명령·임의 경로 쓰기 없음.
  plan.md의 4종에 더해 보류 폴더 영구 삭제(`purgeHolding`, 세션 폴더만)와 복원 시 서비스 재등록
  (`bootstrap`, `/Library/LaunchDaemons/*.plist`만)을 같은 검증으로 둔다 — 기존 엔진 기능(보관 기간·복원)에 필요.
- 경로: 절대 경로·빈/`.`/`..` 구성요소·제어 문자 금지 → 허용 루트 화이트리스트 아래만 → 헬퍼 고정 보호 목록 +
  `SafetyGuard`(plan.md 5.1) → fd 기반 이동.
- fd 기반 이동 (`SecureFileOperations`): 루트부터 `openat(…, O_NOFOLLOW | O_DIRECTORY)`로 내려가며 허용 루트까지는
  소유자(root)·다른 사용자 쓰기 불가(sticky 제외)를 확인, 앱 번들 ID는 fd로 연 Info.plist에서 읽고, 최종 이동은
  `renameatx_np(…, RENAME_EXCL)`. 보류 폴더는 헬퍼가 만든 root 소유 `Holding`(0700)·세션 폴더(0700)만 쓴다.
- 레이블·패키지 ID: `[A-Za-z0-9._-]`, `com.apple.*`·본 앱(헬퍼 포함) 금지. `launchctl`·`pkgutil`은 고정 경로 + 인자 배열.

**테스트** (`CleanerCoreTests/PrivilegedHelperTests`) — 헬퍼가 실행하는 처리기·fd 이동을 일반 사용자로 픽스처 루트에서
실행한다 (plan.md 9장 "권한 경로 보안 테스트"): 허용 루트 밖, 상위 폴더 링크, 검사 직후 상위 폴더·마지막 구성요소를 링크로
바꾸는 훅, 다른 스레드가 링크로 계속 바꾸는 경쟁 조건 반복 실행, 셸 메타문자, RENAME_EXCL 충돌, 보호 목록, 소유자·권한,
보류 폴더 링크. XPC는 같은 프로세스의 익명 리스너로 요구사항 일치·불일치(클라이언트·헬퍼 양쪽)와 대체 경로를 확인한다.
**검증하지 못한 것**: launchd 등록·root 실행·로그인 항목 승인, 실제 Developer ID 서명에서의 요구사항 (#19 이후 수동 확인).

## 브랜치

- `main`: 릴리즈. `dev`: 통합. 기능 브랜치는 `feature/*`로 `dev`에서 분기해 PR로 병합.

## 알려진 제한 (v0.1.0)

| 항목 | 내용 | 해소 시점 |
|---|---|---|
| 관리자 경로 TOCTOU (대체 경로만) | 권한 헬퍼는 fd 기반 이동으로 막는다. 헬퍼가 없을 때 쓰는 `privileged-op.sh`는 구성요소별 `[ -L ]` 검사·허용 루트·보호 목록을 재검증하지만 검사와 `mv` 사이 경쟁 조건이 남는다 | 대체 경로를 쓰는 한 유지 |
| 관리자 인증 횟수 (대체 경로만) | 헬퍼가 있으면 묻지 않는다. 대체 경로에서는 시스템 데몬 중지(종료 전)와 이동·`pkgutil --forget`(종료 후)이 순서상 분리되어 최대 2회 | 대체 경로를 쓰는 한 유지 |
| 권한 헬퍼 서명 | Developer ID가 없어 기본 빌드의 헬퍼는 연결을 받지 않는다 (항상 대체 경로). 실제 등록·승인·서명 요구사항은 수동 확인 전 | #19 |
| 규칙 데이터 서명 키 | `RuleDataVerifier`의 내장 공개키는 개발용. 배포 전 `swift scripts/sign-rule-data.swift keygen`으로 교체 | #20 |
| SwiftUI `@State` | macOS 27 SDK에서 매크로가 되어 CLT에 플러그인이 없음 → 모든 상태를 뷰 모델에 둔다 | — |
| String Catalog | CLT에 `xcstringstool`이 없어 `<언어>.lproj`의 `.strings`·`.stringsdict` 사용 ("번역 추가 절차") | — |
| 픽스처 경로 표기 | 픽스처는 `/var/folders`, 엔진이 해석한 실제 경로는 `/private/var/folders` — 테스트에서 경로 비교 시 realpath로 맞춘다 | — |
