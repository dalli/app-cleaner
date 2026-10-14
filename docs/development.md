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

## 규칙

- 엔진 코드는 `/`·`NSHomeDirectory()`를 직접 쓰지 않는다. 항상 `SystemPaths`를 주입받는다.
- 외부 명령은 `CommandRunning`으로만 실행한다 (셸 문자열 조립 금지).
- 테스트는 `Fixture`의 임시 트리 안에서만 파일을 만들고 지운다. 실제 홈·`/Library`·휴지통을 건드리는 테스트 금지.
- 공용 모델(`Models/`, `Contracts/`)을 바꿔야 하면 하위 호환되게 **추가만** 한다.
- 사용자 표시 문구는 한국어 기본, 내부 용어(bootout, cfprefsd 등)는 "정보원" 칸에만 (ui-ux.md 4.3).

## 브랜치

- `main`: 릴리즈. `dev`: 통합. 기능 브랜치는 `feature/*`로 `dev`에서 분기해 PR로 병합.

## 알려진 제한 (v0.1.0)

| 항목 | 내용 | 해소 시점 |
|---|---|---|
| 관리자 경로 TOCTOU | `privileged-op.sh`는 구성요소별 `[ -L ]` 검사·허용 루트·보호 목록을 재검증하지만 검사와 `mv` 사이 경쟁 조건은 남는다 | Phase 3 헬퍼 |
| 관리자 인증 횟수 | 시스템 데몬 중지(종료 전)와 이동·`pkgutil --forget`(종료 후)이 순서상 분리되어 최대 2회 | Phase 3 헬퍼 |
| 규칙 데이터 서명 키 | `RuleDataVerifier`의 내장 공개키는 개발용. 배포 전 `swift scripts/sign-rule-data.swift keygen`으로 교체 | Phase 4 |
| SwiftUI `@State` | macOS 27 SDK에서 매크로가 되어 CLT에 플러그인이 없음 → 모든 상태를 뷰 모델에 둔다 | — |
| String Catalog | CLT에 `xcstringstool`이 없어 `ko.lproj`/`en.lproj`의 `Localizable.strings` 사용 | — |
| 픽스처 경로 표기 | 픽스처는 `/var/folders`, 엔진이 해석한 실제 경로는 `/private/var/folders` — 테스트에서 경로 비교 시 realpath로 맞춘다 | — |
