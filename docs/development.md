# 개발 가이드

## 빌드·테스트

```sh
swift build
./scripts/test.sh            # Swift Testing (Command Line Tools 환경에서 매크로 플러그인 경로를 지정)
./scripts/test.sh --filter OrphanScannerTests
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
