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
| `AppCleanerGUI` | SwiftUI 앱 (`scripts/build-app.sh`로 `.app` 번들 생성) |
| `AppCleanerSentinel` | 메뉴 막대 상주 Sentinel — 휴지통 감시·정기 고아 스캔 알림 (AppKit만, 본 앱 `Contents/Library/LoginItems`에 들어감) |

### CleanerCore 폴더 소유

| 폴더 | 내용 | plan.md |
|---|---|---|
| `Models/` | 공용 모델 (Candidate, AppIdentity, Plan, Journal …) | — |
| `Environment/` | `SystemPaths`(루트 주입), `CommandRunning`, `BundleInfo`, 코드서명 | 8.2 |
| `Contracts/` | 구성 요소 프로토콜, `CleanerEngine` 파사드, `RuleData` 모델 | 8.2 |
| `Identity/`, `Discovery/`, `Selection/`, `Scanning/` | 앱 제거 탐지 | 4.1~4.3 |
| `Safety/`, `Preflight/`, `Mover/`, `Journal/`, `Execution/` | 정리 실행·기록·복원 | 4.4, 5, 6 |
| `Inventory/`, `Orphan/`, `RuleUpdate/` | 인벤토리·고아 스캔·규칙 데이터 서명 | 4.5, 4.6 |
| `Engine/` | `LiveCleanerEngine` 조립 | 8.2 |
| `Localization/` | `AppLanguage`(언어 선택), `Translations`(엔진·CLI 번역 표 조회) | — |
| `Sentinel/` | Sentinel 판단 로직: 휴지통 유입(`TrashSnapshot`·`TrashedApp`), 일정(`PeriodicScanSchedule`), 알림 여부(`OrphanAlertSummary`), 본 앱 링크(`SentinelLink`), 공용 설정 키 | 7.3 (ui-ux.md S10) |

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
| Sentinel 메뉴·알림 | 한국어 원문 — `S("…")` | 키 자체 (`ko.lproj`에 표 없음) | 같은 폴더 `Sentinel.strings` (+ 영어 복수형 `Sentinel.stringsdict`). Sentinel 번들에도 CleanerCore 리소스 번들을 복사해 넣는다 |

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
| `CleanerCoreTests/SentinelLocalizationTests` | 소스의 모든 `S("…")` 키가 en·ja `Sentinel.*`에 있음, 지정자 일치, 영어 복수형 |
| `CLITests/CLILocalizationTests` | 소스의 모든 `t("…")`·`UsageError("…")` 키가 en·ja `CLI.*`에 있음, ko/en/ja 출력, `--lang`·환경 변수·영어 대체, `--json`이 언어와 무관 |

## Sentinel (휴지통 감시·정기 스캔 알림)

설계와 결정 근거는 `ui-ux.md` S10. 구성 요약:

| 부분 | 위치 |
|---|---|
| 판단 로직 (테스트 대상) | `CleanerCore/Sentinel/` — `SentinelTests`, `SentinelLocalizationTests` |
| 메뉴 막대·FSEvents·알림·CLI 실행 | `Sources/AppCleanerSentinel/` (AppKit, SwiftUI 없음) |
| S7 설정·로그인 항목 등록 | `AppCleanerGUI` `SentinelService`(`SMAppService.loginItem`, 테스트·데모는 메모리 구현), `AppModel.setTrashWatch`·`setPeriodicScan` |
| 본 앱으로 넘기기 | URL 스킴 `com.dallisoft.appcleaner://` (`SentinelLink`) → `AppModel.handleOpen` |
| 번들 | `build-app.sh` → `App Cleaner.app/Contents/Library/LoginItems/App Cleaner Sentinel.app` (`LSUIElement`) |

로그인 항목 등록은 `.app` 번들로 실행했을 때만 된다(`swift run`이면 S7에 "사용할 수 없음"). 이 Mac의 설정을 바꾸지 않고 동작을 보려면
번들 안의 실행 파일을 개발용 인자로 직접 띄운다:

```sh
./scripts/build-app.sh
S="dist/App Cleaner.app/Contents/Library/LoginItems/App Cleaner Sentinel.app/Contents/MacOS/AppCleanerSentinel"
"$S" --log-only --watch-trash --trash /tmp/fake-trash   # 가짜 휴지통 감시, 알림 대신 표준 출력
"$S" --log-only --scan-now                              # 정기 스캔 한 번 (번들 CLI를 자식 프로세스로)
footprint <pid>                                         # 상주 메모리 (phys_footprint)
```

`--log-only`는 알림 권한을 묻지 않고 본 앱 설정(`com.dallisoft.AppCleaner`)에 상태를 쓰지 않는다.

## 브랜치

- `main`: 릴리즈. `dev`: 통합. 기능 브랜치는 `feature/*`로 `dev`에서 분기해 PR로 병합.

## 알려진 제한 (v0.1.0)

| 항목 | 내용 | 해소 시점 |
|---|---|---|
| 관리자 경로 TOCTOU | `privileged-op.sh`는 구성요소별 `[ -L ]` 검사·허용 루트·보호 목록을 재검증하지만 검사와 `mv` 사이 경쟁 조건은 남는다 | Phase 3 헬퍼 (#17) |
| 관리자 인증 횟수 | 시스템 데몬 중지(종료 전)와 이동·`pkgutil --forget`(종료 후)이 순서상 분리되어 최대 2회 | Phase 3 헬퍼 (#17) |
| 규칙 데이터 서명 키 | `RuleDataVerifier`의 내장 공개키는 개발용. 배포 전 `swift scripts/sign-rule-data.swift keygen`으로 교체 | #20 |
| SwiftUI `@State` | macOS 27 SDK에서 매크로가 되어 CLT에 플러그인이 없음 → 모든 상태를 뷰 모델에 둔다 | — |
| String Catalog | CLT에 `xcstringstool`이 없어 `<언어>.lproj`의 `.strings`·`.stringsdict` 사용 ("번역 추가 절차") | — |
| Sentinel 휴지통 읽기 | `~/.Trash`는 TCC로 보호되어 Sentinel(별도 앱)에도 전체 디스크 접근이 필요할 수 있다. 읽지 못하면 메뉴·S7에 안내만 한다. 외장 볼륨 휴지통(`.Trashes`)은 감시하지 않는다 | — |
| Sentinel 실기기 확인 | 로그인 항목 등록(ad-hoc 서명 포함)·실제 알림 표시·알림 동작 버튼은 아직 실기기에서 확인하지 않았다 (가짜 휴지통 폴더로 감지·메모리만 확인) | #18 |
| 픽스처 경로 표기 | 픽스처는 `/var/folders`, 엔진이 해석한 실제 경로는 `/private/var/folders` — 테스트에서 경로 비교 시 realpath로 맞춘다 | — |
