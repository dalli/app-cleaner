# 패키지 매니저로 설치한 CLI 도구 정리 (#39)

`.app`이 아닌 CLI 도구(npm·cargo·pipx·uv로 설치)와 그 데이터, 패키지 매니저 캐시를 찾아 **되돌릴 수 있게** 정리한다.
앱 제거·고아 스캔과 같은 실행 경로(휴지통 이동 + 삭제 기록 + 복원)를 그대로 쓴다.

## 1. 조사 결과

### 1.1 설치 기록 — 파일로 읽을 수 있는가

패키지 매니저 명령을 실행하지 않고 설치 기록 파일만 읽는다 (매니저가 없거나 PATH가 달라도 동작, 셸 미사용).

| 매니저 | 설치 기록 | 설치 항목 | 지원 |
|---|---|---|---|
| npm (`-g`) | `<prefix>/lib/node_modules/<name>/package.json` | 패키지 폴더 + `<prefix>/bin`에서 그 폴더를 가리키는 링크 | ✅ |
| cargo (`install`) | `~/.cargo/.crates2.json` (예전 `.crates.toml`) | `~/.cargo/bin/<bin>` | ✅ |
| pipx | `<PIPX_HOME>/venvs/<name>/pipx_metadata.json` | venv + `~/.local/bin`·`~/.local/share/man`의 링크 | ✅ |
| uv (`tool install`) | `~/.local/share/uv/tools/<name>/uv-receipt.toml` | 도구 폴더 + receipt `install-path` 중 도구 폴더를 가리키는 링크 | ✅ |
| Homebrew formula | `Cellar/<name>/<ver>/INSTALL_RECEIPT.json` | `Cellar` + `opt`·`bin` 링크 + 의존성 | ❌ 아래 |
| bun·pnpm 전역 | `~/.bun/install/global/package.json`, `~/Library/pnpm/global/*/package.json` | `node_modules/<name>` + bin 링크 | ❌ 아래 |
| go (`install`) | 없음 (바이너리 안의 build info뿐) | `~/go/bin/<bin>` | ❌ 아래 |
| gem | `gem` 명령 필요 | 여러 위치 | ❌ |

npm prefix 후보: `/opt/homebrew`, `/usr/local`, `~/.nvm/versions/node/*`, fnm 버전별 폴더, `~/.npmrc`의 `prefix`, `~/.npm-global`, `~/.local`.
node에 딸려 오는 `npm`·`corepack`은 목록에서 뺀다 (지우면 npm 자체가 망가진다).

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

실행 파일 링크는 **설치 폴더를 가리키는 심볼릭 링크만** 설치 항목으로 본다. receipt가 다른 파일을 가리켜도(손상·조작) 옮기지 않는다.
휴지통으로 옮길 때 링크는 링크 자체만 옮겨지고(대상은 그대로), 되돌리면 링크로 복원된다 (테스트 `removeAndRestoreKeepsLinks`).

### 1.3 관리자 소유 위치

root 소유 `/usr/local/lib/node_modules`(공식 node 설치 프로그램) 등 사용자가 쓸 수 없는 위치는 옮기지 않고 매니저 명령(`sudo npm uninstall -g …`)을 안내한다 (`detectOnly`).
관리자 작업 스크립트(`privileged-op.sh`)의 허용 위치는 `/Library`·`/Applications` 아래로 고정되어 있고, 이 범위를 넓히는 것은 Phase 3 권한 헬퍼(#17)에서 다룬다.

### 1.4 데이터 — 이름 기반이라 낮음

패키지 이름(scope 제외)·실행 파일 이름과 같은 폴더를 찾는다: `~/.<name>`, `~/.config/<name>`, `~/.local/share/<name>`, `~/.local/state/<name>`, `~/.cache/<name>`, `~/Library/Application Support/<name>`, `~/Library/Caches/<name>`.

- 신뢰도 **낮음**, 기본 **미선택** (이름만 같은 다른 프로그램의 데이터일 수 있음).
- 짧거나 흔한 이름(4자 미만, `common-names.json`), 보안 폴더(`securityDotfiles`), 패키지 매니저 자신의 폴더(`~/.npm`, `~/.cargo`, `~/.local` …)와 설치 위치를 품는 폴더는 찾지 않는다.
- 여러 설치(예: nvm의 두 node 버전에 같은 패키지)가 같은 폴더를 찾으면 **공유**로 표시한다. CLI `--with-data`는 그 설치를 모두 함께 지울 때만 옮긴다.

### 1.5 패키지 매니저 캐시

| 매니저 | 위치 |
|---|---|
| npm | `~/.npm/_cacache`, `~/.npm/_npx` |
| cargo | `~/.cargo/registry/{cache,src}`, `~/.cargo/git/{checkouts,db}` |
| uv | `~/.cache/uv`, `~/Library/Caches/uv` |
| pipx·pip | `~/.local/pipx/.cache`, `~/Library/Caches/pipx`, `~/Library/Caches/pip`, `~/.cache/pip` |

재생성 가능 · 높음 · 기본 선택. 지우면 다음 설치 때 다시 내려받는다. 매니저가 실행 중일 때는 정리하지 않는 것이 좋다
(`uv cache clean`·`npm cache clean`과 결과는 같지만 휴지통을 거치므로 되돌릴 수 있다).

## 2. 구현

| 위치 | 내용 |
|---|---|
| `CleanerCore/Models/Packages.swift` | `PackageManager`, `InstalledPackage`, `PackageReport`, `PackageScanReport`, `PackageScanOptions` |
| `CleanerCore/Packages/PackageInventory.swift` | 매니저별 설치 기록 읽기 |
| `CleanerCore/Packages/PackageScanner.swift` | 후보 만들기 (설치 항목·데이터·캐시), SafetyGuard·쓰기 권한 판정, 크기 계산 |
| `CleanupPlanner.plan(for: PackageScanReport, …)` | `SessionKind.packageRemoval` 계획 (이동 단계만) |
| `CleanerEngine.scanPackages(options:)` | 엔진 진입점 (기본 구현은 빈 결과 — GUI 데모 엔진) |
| `ItemCategory.package`, `EvidenceSource.packageManager` | 설치 항목 카테고리·정보원 |
| `SafetyGuard.homeExactRoots` | `~/.local/bin`, `~/.cargo/bin`, `~/.local/pipx/venvs`, `~/.local/share/uv/tools` 등 설치 위치의 상위 폴더 자체를 보호 |

### CLI

```sh
appcleaner packages [--manager npm,cargo] [--json]            # 설치 패키지 + 이름이 같은 데이터 (아무것도 지우지 않음)
appcleaner packages remove <이름|경로>… [--with-data] [--dry-run] [--yes] [--json]
appcleaner packages caches [--manager …] [--json]
appcleaner packages caches clean [--manager …] [--dry-run] [--yes] [--json]
```

- 이름은 `@scope/name`, scope를 뺀 이름, `매니저:이름`(예: `npm:typescript`)으로 지정한다. 같은 이름의 설치가 여럿이면 경로(패키지 폴더 또는 실행 파일 링크)로 지정하게 한다.
- 되돌리기는 기존과 같다: `appcleaner history` → `appcleaner restore <세션 ID>`.

## 3. 남은 작업

- GUI 화면 (사이드바 "CLI 도구"): 목록·검사기·정리 시트 — 엔진 API는 준비됨
- bun·pnpm 전역 패키지: 전역 `package.json`에 의존성 기록이 있어 폴더만 옮기면 다음 전역 설치 때 되살아난다 → 기록 갱신 방식(매니저 명령 위임 등) 결정 필요
- Homebrew formula: 의존성·`opt` 링크·`brew` 자체 기록 때문에 파일 이동으로는 안전하게 지울 수 없다 → `brew uninstall` 안내만 검토 (#38과 함께: 설치된 formula의 데이터를 고아로 오판하지 않기)
  - GUI 사이드바 "Homebrew"(⌘4)는 formula·cask 목록·크기·사용자 설치/의존성을 **읽기 전용**으로 보여 주고, 우클릭으로 `brew uninstall [--cask] <이름>` 명령을 복사한다 (`CleanerCore/Inventory/HomebrewInventory.swift` — Cellar·Caskroom의 `INSTALL_RECEIPT.json`만 읽고 `brew`는 실행하지 않음). S1 앱 목록의 "Homebrew" 칩은 cask가 설치한 `.app`만 센다
- go: 설치 기록이 없어 바이너리의 build info(`go version -m`)를 읽어야 한다
- 실행 중인 CLI 도구 프로세스 종료는 하지 않는다 (macOS는 실행 중인 파일도 옮길 수 있다)
