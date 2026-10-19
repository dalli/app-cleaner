# 패키지 매니저로 설치한 CLI 도구 정리 (#39)

`.app`이 아닌 CLI 도구(npm·cargo·pipx·uv·설치 스크립트로 설치)로 설치한 것과 그 데이터, 패키지 매니저 캐시를 찾아 **되돌릴 수 있게** 정리한다.
앱 제거·고아 스캔과 같은 실행 경로(휴지통 이동 + 삭제 기록 + 복원)를 그대로 쓴다.

## 1. 조사 결과

### 1.1 설치 기록 — 파일로 읽을 수 있는가

패키지 매니저 명령을 실행하지 않고 설치 기록 파일만 읽는다 (매니저가 없거나 PATH가 달라도 동작, 셸 미사용).

| 매니저 | 설치 기록 | 설치 항목 | 지원 |
|---|---|---|---|
| npm (`-g`) | `<prefix>/lib/node_modules/<name>/package.json` | 패키지 폴더 + `<prefix>/bin`에서 그 폴더를 가리키는 링크 | ✅ |
| bun (`add -g`) | `~/.bun/install/global/node_modules/<name>/package.json` | 패키지 폴더 + `~/.bun/bin`의 링크 | ✅ (제거는 명령 위임, 1.5) |
| pnpm (`add -g`) | `~/Library/pnpm/global/<major>/node_modules/<name>/package.json` | 패키지 폴더(링크) + `~/Library/pnpm`의 링크 | ✅ (제거는 명령 위임, 1.5) |
| cargo (`install`) | `~/.cargo/.crates2.json` (예전 `.crates.toml`) | `~/.cargo/bin/<bin>` | ✅ |
| pipx | `<PIPX_HOME>/venvs/<name>/pipx_metadata.json` | venv + `~/.local/bin`·`~/.local/share/man`의 링크 | ✅ |
| uv (`tool install`) | `~/.local/share/uv/tools/<name>/uv-receipt.toml` | 도구 폴더 + receipt `install-path` 중 도구 폴더를 가리키는 링크 | ✅ |
| standalone (설치 스크립트) | **없음** — 규칙 데이터 `standalone-tools.json`이 실행 파일·데이터 경로를 알려 준다 | 그 실행 파일 경로들 | ✅ |
| Homebrew formula | `Cellar/<name>/<ver>/INSTALL_RECEIPT.json` | `Cellar` + `opt`·`bin` 링크 + 의존성 | ❌ 아래 |
| go (`install`) | 없음 (바이너리 안의 build info뿐) | `~/go/bin/<bin>` | ❌ 아래 |
| gem | `gem` 명령 필요 | 여러 위치 | ❌ |

npm·bun·pnpm은 전역 설치 구조가 같아(`node_modules/<name>` + bin 링크) 스캔을 공유한다. 다른 점은 두 가지다.

- **전이 의존성 표시** — bun·pnpm은 전역 `package.json`의 `dependencies`가 **직접 설치분만** 적는다. 그래서 그 목록에 없는 폴더
  (전이 의존성)는 다른 패키지가 쓰고 있는 것이므로 지울 수 있는 항목이 아니어서 목록에서 뺀다. 기록을 못 읽으면 필터를 끄고
  전부 보여 준다(숨기는 쪽이 더 위험하다). npm 전역에는 루트 `package.json`이 없어 이 구분이 불가능하므로 기존대로 폴더를 모두 보여 준다.
- **제거 방식** — 아래 1.5.

npm prefix 후보: `/opt/homebrew`, `/usr/local`, `~/.nvm/versions/node/*`, fnm 버전별 폴더, `~/.npmrc`의 `prefix`, `~/.npm-global`, `~/.local`.
node에 딸려 오는 `npm`·`corepack`은 목록에서 뺀다 (지우면 npm 자체가 망가진다).

### 1.1.1 설치 스크립트(standalone) — 기록이 없는 도구

`curl … | sh`로 설치하는 도구(opencode·omo·claude·codex·bun·deno 등)는 **설치 기록을 남기지 않는다.**
실행 파일 하나와 데이터 폴더만 있는 경우가 많아 다른 매니저 탐지로는 아예 잡히지 않는다. 두 경로로 찾는다.

| 방법 | 대상 | 신뢰도 | 기본 선택 |
|---|---|---|---|
| 규칙 데이터 | `standalone-tools.json`의 `executables` 경로 중 **존재하는 것** | 높음 | ✅ |
| 자동 탐지 | `~/.local/bin`·`~/bin`의 실행 파일 중 다른 매니저·규칙 데이터가 설명하지 않는 것 | 낮음 | ❌ |

- 규칙 데이터 항목: `name`, `executables`(실행 파일 경로, 앞에 있는 것부터 확인), `versionFiles`(버전 파일),
  `dataPaths`(데이터 폴더 — **이름 추측을 하지 않고 이 목록만 따른다**), `reinstall`(재설치 안내).
  `dataPaths`는 `~/` 를 쓰고 외부 데이터와 같이 `paths.mapExternalPath`로 푼다.
- 자동 탐지는 **사용자 소유 bin 폴더만** 본다. `/usr/local/bin`처럼 관리자 소유인 곳은 옮길 수 없고 공식 설치 프로그램과 구분도
  안 되므로, 규칙 데이터(예: `ollama`)로만 잡는다.
- 자동 탐지에서 **심볼릭 링크는 제외한다.** 링크라면 다른 매니저 설치 항목이거나(링크 대상만 옮기면 다른 프로그램을 망가뜨린다),
  규칙 데이터가 정한 도구다.
- 데이터 폴더에 실행 파일이 있어도(`~/.bun` 안에 `~/.bun/bin/bun`) 규칙 데이터가 정한 데이터로 보여 준다.
  이름 추칭 데이터는 반대로 설치 위치를 품으면 건너뛴다(옮기면 실행 파일까지 사라짐). 계획 단계에서 중복은 정리된다.
- 지운 뒤에는 설치 기록이 없어 **설치 스크립트를 다시 실행해야 한다.** 재설치 명령을 규칙 데이터에 담아 안내한다.
  짐작한 항목은 설치 방법 자체를 알 수 없으므로 제거 시 경고를 함께 낸다.

### 1.2 제거 방식 — 매니저 명령 대신 파일 이동

| 방식 | 장점 | 단점 |
|---|---|---|
| `npm uninstall -g` 등 매니저 명령 실행 | 매니저의 기록이 정확히 갱신됨 | **영구 삭제** — 되돌릴 수 없음. 매니저 경로·버전(nvm 등)에 따라 다른 prefix를 건드릴 수 있음 |
| **설치 항목을 휴지통으로 이동 (채택)** | 삭제 기록으로 되돌릴 수 있음. 앱 제거와 같은 안전장치(SafetyGuard 재검사, 보호 목록) | 매니저가 따로 두는 기록이 남을 수 있음 (아래) |

매니저별로 이동 후 남는 기록:

| 매니저 | 남는 것 | 영향 |
|---|---|---|
| npm | `lib/node_modules/.package-lock.json`(숨은 lockfile) | npm이 `node_modules`가 더 최근에 바뀌었으면 무시하고 다시 만든다. 영향 없음 |
| cargo | `.crates2.json`의 항목 | `cargo install --list`에 남는다. 다시 설치하면 실행 파일이 없으므로 그대로 설치되고 기록이 갱신된다. 안내 문구로 알린다 |
| pipx·uv | 없음 (venv·도구 폴더 자체가 기록) | — |
| standalone | 없음 (설치 기록을 남기지 않는다) | 지운 뒤 설치 스크립트를 다시 실행해야 한다. 재설치 명령을 안내한다 |
| **bun·pnpm** | `package.json`·`bun.lock`/`pnpm-lock.yaml` 항목 | **다음 전역 설치 때 되살아난다** — 그래서 옮기지 않는다 (1.5) |

실행 파일 링크는 **설치 폴더를 가리키는 심볼릭 링크만** 설치 항목으로 본다. receipt가 다른 파일을 가리켜도(손상·조작) 옮기지 않는다.
휴지통으로 옮길 때 링크는 링크 자체만 옮겨지고(대상은 그대로), 되돌리면 링크로 복원된다 (테스트 `removeAndRestoreKeepsLinks`).

### 1.2.1 bun·pnpm — 파일 이동으로 지워지지 않는다 (샌드박스 실험)

`BUN_INSTALL`·`PNPM_HOME`을 임시 폴더로 옮겨 실제 설치 후 다음을 확인했다. 사용자 홈의 실제 설치 폴더는 건드리지 않았다.

| 실험 | 결과 |
|---|---|
| 전역 패키지 폴더만 휴지통으로 이동 → 다른 패키지 전역 설치 | **되살아남** |
| 폴더 이동 + 전역 `package.json`에서 항목 제거 | **여전히 되살아남** (`bun.lock`이 기준) |
| `bun remove -g <name>` / `pnpm remove -g <name>` | 기록이 정확히 갱신됨 (하지만 영구 삭제) |

npm은 숨은 lockfile을 무시하고 다시 만들어서 파일 이동으로 끝나지만(1.2), bun·pnpm은 **잠금 파일이 기준**이라 그렇지 않다.
옮기면 사용자는 "지웠다"고 믿지만 실제로는 그대로인 최악의 상태가 되므로, **옮기지 않고 제거 명령만 안내한다**
(`PackageManager.isCommandOnly` — Homebrew 화면과 같은 "읽기 전용 + 명령 복사" 방식). 목록에 `[제거 명령만 · 되돌리기 불가]`로 표시된다.

### 1.2.2 왜 Homebrew 레벨 메뉴를 따로 만들지 않았나

bun은 런타임·전역 패키지·캐시를 함께 다루므로 별도 메뉴 후보처럼 보이지만, **메뉴를 나눌 기준은 매니저 종류가 아니라
동작 모드(옮길 수 있음 / 명령 위임)**다. bun이 명령 위임이 되는 이유는 위 실험 때문이고, 그와 같은 이유 Homebrew도
메뉴를 가진다. 그런데 그 "읽기 전용 + 명령 복사" 패턴은 이미 패키지 목록 안에 있다 — root 소유 npm prefix가
`detectOnly` + `packageNeedsAdmin`("관리자 소유 위치라 옮기지 않음 — `sudo npm uninstall -g …` 로 제거")로 처리된다.
bun·pnpm을 같은 경로에 붙이면 화면·규칙이 하나씩만 늘어난다. 캐시도 마찬가지로 npm `_cacache`·cargo `registry/cache`·uv·pipx가
이미 "패키지 매니저 캐시" 한 목록에 모여 있으므로 bun cache·pnpm store도 그곳에 붙인다.

### 1.3 관리자 소유 위치

root 소유 `/usr/local/lib/node_modules`(공식 node 설치 프로그램) 등 사용자가 쓸 수 없는 위치는 옮기지 않고 매니저 명령(`sudo npm uninstall -g …`)을 안내한다 (`detectOnly`).
설치 스크립트 도구에도 적용하되, 제거 명령이 없으므로 "직접 정리하세요"와 경로를 안내한다 (`EngineText.standaloneNeedsAdmin`).
관리자 작업 스크립트(`privileged-op.sh`)의 허용 위치는 `/Library`·`/Applications` 아래로 고정되어 있고, 이 범위를 넓히는 것은 Phase 3 권한 헬퍼(#17)에서 다룬다.

### 1.4 데이터 — 설치 기록이 있는 도구는 이름 기반이라 낮음

패키지 이름(scope 제외)·실행 파일 이름과 같은 폴더를 찾는다: `~/.<name>`, `~/.config/<name>`, `~/.local/share/<name>`, `~/.local/state/<name>`, `~/.cache/<name>`, `~/Library/Application Support/<name>`, `~/Library/Caches/<name>`.

- 신뢰도 **낮음**, 기본 **미선택** (이름만 같은 다른 프로그램의 데이터일 수 있음).
- 짧거나 흔한 이름(4자 미만, `common-names.json`), 보안 폴더(`securityDotfiles`), 패키지 매니저 자신의 폴더(`~/.npm`, `~/.cargo`, `~/.local` …)와 설치 위치를 품는 폴더는 찾지 않는다.
- 여러 설치(예: nvm의 두 node 버전에 같은 패키지)가 같은 폴더를 찾으면 **공유**로 표시한다. CLI `--with-data`는 그 설치를 모두 함께 지울 때만 옮긴다.
- **규칙 데이터에 있는 설치 스크립트 도구는 예외**다. `dataPaths`에 적힌 폴더만 보고(이름 추측 없음), 그 안에 실행 파일이 있어도 보여 준다.

### 1.5 패키지 매니저 캐시

| 매니저 | 위치 |
|---|---|
| npm | `~/.npm/_cacache`, `~/.npm/_npx` |
| cargo | `~/.cargo/registry/{cache,src}`, `~/.cargo/git/{checkouts,db}` |
| uv | `~/.cache/uv`, `~/Library/Caches/uv` |
| pipx·pip | `~/.local/pipx/.cache`, `~/Library/Caches/pipx`, `~/Library/Caches/pip`, `~/.cache/pip` |
| bun | `~/.bun/install/cache` |
| pnpm | `~/Library/pnpm/store` (버전별 `v3`·`v10`·`v11`이 함께 있다) |

재생성 가능 · 높음 · 기본 선택. 지우면 다음 설치 때 다시 내려받는다. 매니저가 실행 중일 때는 정리하지 않는 것이 좋다
(`uv cache clean`·`npm cache clean`과 결과는 같지만 휴지통을 거치므로 되돌릴 수 있다).

pnpm store는 전역 설치뿐 아니라 **로컬 프로젝트도 하드링크로 참조한다.** 지워도 재생성되지만 프로젝트 빌드 성능에 영향을 주는
만큼, 다른 캐시와 같은 기본 선택을 유지하면서도 `pnpm store prune`을 안내할 수 있도록 매니저 이름을 함께 보여 준다.
전역 설치 폴더(`~/.bun/install/global`)와는 다른 곳이라 따로 관리한다 — 캐시 한 벌로 합치지 않는다.

## 2. 구현

| 위치 | 내용 |
|---|---|
| `CleanerCore/Models/Packages.swift` | `PackageManager`, `Detection`, `InstalledPackage`, `PackageReport`, `PackageScanReport`, `PackageScanOptions` |
| `CleanerCore/Contracts/RuleData.swift` | `StandaloneTool`(규칙 데이터 항목), `RuleData.standaloneTools` |
| `CleanerCore/Resources/RuleData/standalone-tools.json` | 설치 스크립트 도구의 실행 파일·버전 파일·데이터 폴더·재설치 명령 |
| `CleanerCore/Packages/PackageInventory.swift` | 매니저별 설치 기록 읽기, npm 계열 공유 스캔 `nodePackages()`, `standalonePackages()`·`guessedStandalonePackages()` |
| `CleanerCore/Packages/PackageScanner.swift` | 후보 만들기 (설치 항목·데이터·캐시), SafetyGuard·쓰기 권한 판정, 크기 계산 |
| `CleanupPlanner.plan(for: PackageScanReport, …)` | `SessionKind.packageRemoval` 계획 (이동 단계만) |
| `CleanerEngine.scanPackages(options:)` | 엔진 진입점 (기본 구현은 빈 결과 — GUI 데모 엔진) |
| `ItemCategory.package`, `EvidenceSource.packageManager`·`.standaloneScript` | 설치 항목 카테고리·정보원 |
| `SafetyGuard.homeExactRoots` | `~/.local/bin`, `~/.cargo/bin`, `~/.local/pipx/venvs`, `~/.local/share/uv/tools`, `~/.bun`, `~/.bun/install/global/node_modules`, `~/Library/pnpm`, `~/bin` 등 설치 위치의 상위 폴더 자체를 보호 |

### CLI

```sh
appcleaner packages [--manager npm,cargo] [--json]            # 설치 패키지 + 이름이 같은 데이터 (아무것도 지우지 않음)
appcleaner packages remove <이름|경로>… [--with-data] [--dry-run] [--yes] [--json]
appcleaner packages caches [--manager …] [--json]
appcleaner packages caches clean [--manager …] [--dry-run] [--yes] [--json]
```

- 이름은 `@scope/name`, scope를 뺀 이름, `매니저:이름`(예: `npm:typescript`, `standalone:omo`)으로 지정한다. 같은 이름의 설치가 여럿이면 경로(패키지 폴더 또는 실행 파일 링크)로 지정하게 한다.
- 짐작한 항목(`[신뢰도 낮음 · 설치 방식 미확인]`)은 기본 미선택이지만, 이름을 직접 적어 제거하면 경고와 함께 옮긴다 — 확인 질문·`--dry-run`·되돌리기는 그대로 지킨다.
- bun·pnpm 항목(`[제거 명령만 · 되돌리기 불가]`)은 `packages remove`로 옮기지 않는다. `bun remove -g <이름>` / `pnpm remove -g <이름>`을 안내한다 (1.2.1).
- 되돌리기는 기존과 같다: `appcleaner history` → `appcleaner restore <세션 ID>`.

## 3. 남은 작업

- GUI 화면 (사이드바 "CLI 도구"): 목록·검사기·정리 시트 — 엔진 API는 준비됨. bun·pnpm·standalone의 **[제거 명령만]** 항목은 명령 복사 버튼이 필요하다
- `standalone-tools.json` 확장: 설치 스크립트 도구를 계속 늘린다. 버전 파일이 있는 도구(`versionFiles`)를 늘리면 버전이 보인다
- npm 전역의 직접/전이 의존성 구분: 루트 `package.json`이 없어 지금은 폴더를 모두 보여 준다. npm이 숨은 lockfile을 쓰는 prefix에서만 구분할 수 있어 더 살펴볼 필요는 낮다
- Homebrew formula: 의존성·`opt` 링크·`brew` 자체 기록 때문에 파일 이동으로는 안전하게 지울 수 없다 → `brew uninstall` 안내만 검토 (#38과 함께: 설치된 formula의 데이터를 고아로 오판하지 않기)
  - GUI 사이드바 "Homebrew"(⌘4)는 formula·cask 목록·크기·사용자 설치/의존성을 **읽기 전용**으로 보여 주고, 우클릭으로 `brew uninstall [--cask] <이름>` 명령을 복사한다 (`CleanerCore/Inventory/HomebrewInventory.swift` — Cellar·Caskroom의 `INSTALL_RECEIPT.json`만 읽고 `brew`는 실행하지 않음). S1 앱 목록의 "Homebrew" 칩은 cask가 설치한 `.app`만 센다
- go: 설치 기록이 없어 바이너리의 build info(`go version -m`)를 읽어야 한다
- 실행 중인 CLI 도구 프로세스 종료는 하지 않는다 (macOS는 실행 중인 파일도 옮길 수 있다)
