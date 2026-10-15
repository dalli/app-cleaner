# QA 보고서 — 성능 (#21)

> 기준 문서: `docs/plan.md` 8.3 성능 목표, 9장 테스트 전략 · 대상 이슈: #21 "QA: VM·실기기 테스트 매트릭스"의 **성능** 항목
> 측정일: 2026-10-14 · 대상: `appcleaner` 0.2.0 (규칙 데이터 `2026.10.14-seed`), `dev` 브랜치 릴리즈 빌드

이 보고서는 #21 중 **읽기 전용으로 확인할 수 있는 성능 항목**만 다룬다. 앱 검사(`scan`)와 고아 스캔(`orphans`, 목록 출력만)만 실행했고,
`remove`·`orphans clean`·`restore`는 실행하지 않았다. 실제 이동·복원·관리자 경로가 필요한 나머지 항목은 [5장](#5-남은-21-항목-vm실기기-필요)에 정리했다.

---

## 1. 요약

| 목표 (plan.md 8.3) | 결과 | 판정 |
|---|---|---|
| 앱 1개 검사 2초 이내 | 인벤토리 캐시가 있을 때 12개 앱 중 9개 통과 (중앙값 0.41~1.22초). **Google 계열 3개 앱은 2.01~2.20초로 초과** | ⚠️ 부분 통과 |
| 고아 스캔 첫 실행 30초 이내 | 캐시 없음 4회 중앙값 **6.72초** (최대 11.37초) | ✅ 통과 |
| 고아 스캔 캐시 사용 시 10초 이내 | 5회 중앙값 **4.92초** (최대 5.98초) | ✅ 통과 |
| 픽스처 성능 테스트 (`slackLikeEndToEnd`) | 0.053초 | ✅ 통과 |

- 앱 검사 시간을 좌우하는 것은 탐지가 아니라 **크기 계산**이다. 공유 벤더 폴더(`~/Library/Caches/Google`, 파일 26.9만 개·7.3 GB)는 기본 미선택인데도 검사 결과를 돌려주기 전에 크기를 끝까지 센다 → [4.1](#41-공유-벤더-폴더의-크기-계산이-앱-검사를-지배한다).
- CLI는 GUI와 달리 인벤토리를 미리 만들지 않아(`prewarm` 없음), 캐시가 없을 때 첫 검사에 인벤토리 구축 시간(약 1~1.7초)이 더해진다 → [4.2](#42-cli-첫-검사의-인벤토리-구축).

---

## 2. 환경

| 항목 | 값 |
|---|---|
| 기기 | MacBook Pro (Mac16,6), Apple M4 Max (14코어: 성능 10 · 효율 4), 메모리 36 GB, 내장 SSD |
| OS | macOS 27.0.1 (26A434) |
| 툴체인 | Command Line Tools, Swift 6.4 (`swift build -c release --product appcleaner`) |
| CLI | `appcleaner 0.2.0 (rule data 2026.10.14-seed)` |
| `/Applications` | 최상위 `.app` 36개 (하위 폴더 포함 55개) |
| 인벤토리 | 설치 앱 **425개** (`/System/Applications`, CoreServices, `~/Applications`의 Chrome 웹 앱, Spotlight 결과 포함) |
| Spotlight | 색인 활성, 교차 검증 완료 (`complete: true`, 누락 앱 0) |
| 전체 디스크 접근 권한(FDA) | **있음** — 측정을 실행한 셸의 책임 프로세스 기준. `~/Library/Safari/Bookmarks.plist` 읽기 성공, `~/Library/Containers/com.apple.stocks` 목록 읽기 성공 (`PermissionProbe`와 같은 탐침) |
| 부하 | 일반 개발 환경 그대로 측정 (WindowServer, 실행 중인 VM 1개, 다른 셸의 node 프로세스 등). 측정 중 1분 부하 평균 4.9~13 |

FDA가 없으면 컨테이너·Safari 등 보호 경로를 읽지 못해 후보 수와 시간이 달라진다. FDA 없음 환경의 측정은 [5장](#5-남은-21-항목-vm실기기-필요)의 권한 항목과 함께 VM에서 한다.

---

## 3. 방법과 결과

### 3.1 픽스처 성능 테스트

```sh
APPCLEANER_PERF=1 ./scripts/test.sh --filter slackLikeEndToEnd
```

`ScanningAppScannerTests/slackLikeEndToEnd`가 **0.053초**에 통과했다 (`APPCLEANER_PERF=1`일 때만 2초 기준을 `#expect`로 검사).
픽스처는 작은 가짜 트리라 실제 환경의 크기 계산 비용은 반영하지 않는다.

### 3.2 앱 1개 검사 (`scan`)

```sh
/usr/bin/time -p .build/release/appcleaner --lang en scan --json <앱 경로>   # 앱마다 3회
```

- 벽시계 시간(`real`)을 쟀다. 프로세스 시작·JSON 출력 포함.
- 인벤토리 캐시(`~/Library/Application Support/AppCleaner/inventory-cache.json`)가 있는 상태. 앱 검사는 캐시 나이와 관계없이 캐시를 쓴다.
- 1회차는 OS 파일 캐시가 비어 있을 수 있어 느리다. 판정은 3회 **중앙값**으로 한다.

| 앱 | 유형 | 3회 (초) | 중앙값 | 찾은 항목 / 기본 선택 | 판정 |
|---|---|---|---|---|---|
| Visual Studio Code | Electron | 2.01 · 1.21 · 1.21 | 1.21 | 113 / 9 | ✅ |
| Discord | Electron | 1.23 · 0.73 · 0.72 | 0.73 | 14 / 12 | ✅ |
| Antigravity | Electron (Google) | 2.20 · 2.24 · 2.20 | **2.20** | 26 / 11 | ❌ |
| Telegram | Mac App Store 샌드박스 | 1.13 · 0.70 · 0.68 | 0.70 | 41 / 37 | ✅ |
| RunCat | Mac App Store 샌드박스 (소형) | 0.44 · 0.41 · 0.40 | 0.41 | 15 / 13 | ✅ |
| Microsoft Word | Mac App Store + 공유 그룹 컨테이너(Office) | 1.22 · 1.29 · 1.22 | 1.22 | 140 / 34 | ✅ |
| Developer | Apple 제작 (App Store, BID `developer.apple.*`) | 0.80 · 0.72 · 0.73 | 0.73 | 34 / 31 | ✅ |
| Hancom Office HWP | `.pkg` 설치 | 0.62 · 0.58 · 0.58 | 0.58 | 32 / 30 | ✅ |
| Google Drive | `.pkg` 설치 (Keystone, 확장 다수) | 6.18 · 2.18 · 2.07 | **2.18** | 63 / 55 | ❌ |
| Google Chrome | 직접 설치 (Keystone) | 2.01 · 2.03 · 2.01 | **2.01** | 29 / 13 | ❌ |
| Docker | 직접 설치 (권한 헬퍼·LaunchDaemon) | 0.65 · 0.52 · 0.51 | 0.52 | 69 / 63 | ✅ |
| CodexBar | Homebrew Cask | 0.47 · 0.47 · 0.48 | 0.47 | 31 / 29 | ✅ |
| Safari · Notes · Xcode | Apple 앱 (`com.apple.*`) | 0.02~0.03 | — | 검사 거부 ("Apple apps can't be removed") | 해당 없음 |

`com.apple.*` 앱은 보호 목록에 따라 검사 전에 거부되므로 성능 측정 대상이 아니다. Apple 제작 앱의 대표로는 BID가 `com.apple.`이 아닌 Developer를 썼다.

**인벤토리 캐시가 없을 때** (캐시 파일을 옮겨 두고 1회씩):

| 앱 | 시간 (초) | 캐시 있을 때 중앙값 | 차이 |
|---|---|---|---|
| RunCat | 1.37 | 0.41 | +0.96 |
| Telegram | 2.11 | 0.70 | +1.41 |
| Visual Studio Code | 2.94 | 1.21 | +1.73 |

### 3.3 고아 스캔 (`orphans`)

```sh
/usr/bin/time -p .build/release/appcleaner --lang en orphans --json   # 목록만 출력, `clean` 없음
```

- 인벤토리 캐시는 `~/Library/Application Support/AppCleaner/inventory-cache.json` 하나다 (서명 정보 캐시 포함). 고아 스캔은 만든 지 **300초** 안이고 표준 위치 앱 목록이 그대로일 때만 캐시를 쓴다 (`OrphanScanner.inventoryCacheMaxAge`).
- 원래 캐시 파일을 복사해 두고, "캐시 없음" 측정 전마다 직전 실행이 만든 캐시 파일을 작업 폴더 밖으로 옮겼다. 측정 후 원래 파일(수정일 16:22)을 되돌려 놓았다. `Journal/` 등 다른 파일은 건드리지 않았다.
- sudo 없이는 OS 파일 캐시를 비울 수 없으므로 "캐시 없음"은 **앱 인벤토리 캐시가 없다**는 뜻이지 디스크가 완전히 차가운 상태는 아니다.
- CLI는 크기 계산까지 끝난 뒤 출력하므로 아래 시간에는 크기 계산이 포함된다 (GUI는 결과를 먼저 보이고 크기를 이어서 계산 — plan.md 8.3).
- 결과는 모든 실행에서 같았다: 설치 앱 425개, 그룹 154개 · 항목 242개 (보통 37 · 낮음 117 · 높음 0), 경고 0, 크기 합계 55.8 GB · 파일 12.7만 개.

| 상태 | 실행 (초, 벽시계) | 중앙값 | 목표 | 판정 |
|---|---|---|---|---|
| 캐시 없음 (첫 실행) | 5.05 · 6.65 · 11.37 · 6.78 | **6.72** | 30초 | ✅ |
| 캐시가 오래됨 → 재구축 (서명 캐시는 재사용) | 7.60 (1회, 그날 첫 실행) | — | 30초 | ✅ |
| 캐시 사용 | 4.75 · 4.70 · 4.92 · 5.14 · 5.98 | **4.92** | 10초 | ✅ |

11.37초는 다른 셸의 node 프로세스 4개가 CPU를 쓰던 때(부하 평균 6~13)의 측정이다. 엔진이 보고한 `duration`과 벽시계 차이는 0.03초 이내였다.

---

## 4. 발견 사항

### 4.1 공유 벤더 폴더의 크기 계산이 앱 검사를 지배한다

목표를 넘은 세 앱(Google Drive, Chrome, Antigravity)은 모두 Google 벤더 공용 폴더를 후보로 포함한다.

| 후보 | 파일 수 | 크기 | 상태 |
|---|---|---|---|
| `~/Library/Caches/Google` | 269,142 | 7.3 GB | 낮음 · 공유 (같은 개발사 앱 8개) · 미선택 |
| `~/Library/Application Support/Google` | 29,894 | 10.8 GB | 낮음 · 공유 · 미선택 |

`AppScanner`는 결과를 돌려주기 전에 모든 후보에 `FileStatsCalculator.fill`을 실행한다 (`Sources/CleanerCore/Scanning/AppScanner.swift`).
Chrome 검사에서 세는 파일 30만 개 중 99%가 위 두 폴더이고, 같은 폴더를 `du -sk`로 읽는 데에도 수 초가 걸렸다.
기본 선택하지 않는 공유 항목 때문에 검사 전체가 늦어지므로, 고아 스캔처럼 **결과를 먼저 보내고 크기는 이어서 계산**하거나 미선택·공유 항목의 크기를 지연 계산하는 개선을 검토할 만하다.
VS Code(`~/.vscode` 3.7만 개, `Application Support/Code` 2.9만 개)와 Word(앱 번들 4.8만 개)도 같은 이유로 1.2초대다.

### 4.2 CLI 첫 검사의 인벤토리 구축

`LiveCleanerEngine.scan`은 캐시가 없으면 인벤토리를 먼저 만든다. GUI는 시작할 때 `prewarm()`으로 미리 만들지만 CLI에는 이 단계가 없어,
캐시가 없는 첫 `appcleaner scan`은 1.0~1.7초가 더해져 VS Code 2.94초, Telegram 2.11초로 목표를 넘었다.
plan.md 8.3의 "앱 1개 2초"를 캐시가 있는 상태 기준으로 볼지, CLI 첫 실행도 포함할지 정해 둘 필요가 있다.

### 4.3 고아 스캔은 목표 대비 여유가 크다

캐시 사용 시 약 4.9초 중 인벤토리는 거의 들지 않고, 대부분은 후보 수집·판정과 크기 계산(55.8 GB, 12.7만 파일)이다.
캐시 없음과 캐시 사용의 차이는 1~2초로, 인벤토리 구축(서명 읽기 425개 포함)이 생각보다 싸다.

---

## 5. 남은 #21 항목 (VM·실기기 필요)

이번 측정은 개발 Mac에서 읽기 전용으로만 했다. 아래 항목은 실제 이동·복원·권한 변경이 필요해 **수행하지 않았다**.

| 항목 | 필요한 환경 | 비고 |
|---|---|---|
| macOS VM 구성 (Virtualization.framework) | VM | Apple ID 로그인은 macOS 15+ 호스트·게스트만 가능 → macOS 14 App Store 앱은 실기기 전용 계정 |
| 실제 앱 QA: 설치·사용·삭제 후 잔여물 0건 | VM | Mac App Store 샌드박스, Electron(Cursor, Slack), `.pkg`(데몬 포함), Homebrew Cask, 로그인 항목, `SMAppService` 데몬, Office 그룹 컨테이너 묶음 |
| Pre-flight | VM | `KeepAlive` 에이전트 bootout → 종료 순서로 재실행 없음, LaunchServices 미등록 헬퍼 종료 |
| 고아 스캔 정탐 | VM | 앱 본체만 삭제한 상태(5개 유형)에서 높음·보통으로 모두 찾는지 |
| 복원 | VM | 되돌리기 후 앱 정상 동작, LaunchDaemon `launchctl bootstrap` 로드(소유자·권한 보존), 휴지통 비운 뒤 부분 복원 표시 |
| 관리자 경로 | VM | osascript 인증 1회 묶음, 인증 취소 시 해당 항목만 실패, root 소유 앱 번들의 `NSWorkspace.recycle` OS별 동작 |
| 권한 | VM | FDA 없음/있음, 컨테이너 접근 확인창(14+), Group Containers 확인창(15+), App Management 거부 안내 |
| 성능 (FDA 없음 · 다른 기기) | VM 또는 실기기 | 이번 측정은 FDA 있음 · M4 Max 1대. 저사양 기기와 FDA 없음 환경에서 다시 잰다 |
| 완료 기준 "오삭제 0건" | VM | 위 항목을 마친 뒤 이 보고서에 결과를 덧붙인다 |
