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

## CLI

```sh
appcleaner scan "/Applications/Foo.app"          # 검사만 (아무것도 지우지 않음)
appcleaner remove Foo --dry-run                  # 정리 계획 JSON
appcleaner remove Foo                            # 확인 후 휴지통/보류 폴더로 이동
appcleaner orphans --min-confidence medium       # 고아 잔여물 스캔
appcleaner orphans clean --dry-run               # 고아 정리 계획 (기본: 높음 + 사용자 데이터 아님)
appcleaner history                               # 삭제 기록
appcleaner restore <세션 ID>                     # 되돌리기
```

`.app` 번들 안의 `Contents/Helpers/appcleaner`가 CLI다.

## 안전 원칙

- 영구 삭제하지 않는다: 사용자 파일은 휴지통, root 소유 파일은 보류 폴더(`/Library/Application Support/AppCleaner/Holding`)로 옮기고 삭제 기록으로 되돌린다.
- 신뢰도 낮음·다른 앱과 공유·사용자 데이터는 기본 선택하지 않는다. iCloud 데이터·기기 백업·`~/.ssh` 등은 선택할 수 없다.
- 관리자 작업은 번들의 고정 스크립트(`privileged-op.sh`, 해시 확인)만 실행하며 권한 상승된 쪽에서 경로를 다시 검증한다.

## 현재 상태 (v0.1.0 — MVP)

plan.md의 Phase 1a·1b·2 범위. 아직 남은 것:

- Phase 3: SMAppService 권한 헬퍼(XPC, fd 기반 이동)로 AppleScript 관리자 경로 교체 — 현재 경로는 검사와 이동 사이 경쟁 조건(TOCTOU)이 알려진 제한
- Phase 4: Developer ID 서명·공증, Sparkle 업데이트, Homebrew Cask 배포, 규칙 데이터 서명 키 교체(현재 내장 공개키는 개발용)
- 실기기·VM QA 매트릭스 (plan.md 9장)
