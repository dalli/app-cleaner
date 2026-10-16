# PROJECT KNOWLEDGE BASE

**Generated:** 2026-10-16 11:58 KST
**Commit:** 3c06184
**Branch:** fix/release-smoke-check

## OVERVIEW
App Cleaner: a macOS 14+ app uninstaller and leftover/orphan cleaner (open source, dallisoft). Pure SwiftPM (tools 6.0, no external deps), built and tested with Command Line Tools only (no Xcode). It ships a SwiftUI GUI, a CLI, a menu-bar Sentinel, and a root LaunchDaemon helper, all over one engine (`CleanerCore`). Docs and code comments are Korean.

## STRUCTURE
```
app-cleaner/
├── Sources/
│   ├── CleanerCore/         # engine + bundled RuleData/Scripts/Localization (own AGENTS.md)
│   ├── AppCleanerGUI/       # SwiftUI app (own AGENTS.md)
│   ├── appcleaner/          # CLI: Arguments.swift parser -> CLI.run; version literal in CLI.swift
│   ├── AppCleanerSentinel/  # AppKit-only menu-bar login item: TrashMonitor (FSEvents), PeriodicScanRunner (spawns bundled CLI)
│   ├── AppCleanerHelper/    # main.swift only: XPC listener; logic lives in CleanerCore/Privileged
│   └── CleanerTestSupport/  # Fixture, StubCommandRunner, StubSignatureReader
├── Tests/                   # CleanerCoreTests, AppCleanerGUITests, CLITests (Swift Testing)
├── scripts/                 # build-app.sh, package-release.sh, test.sh, rule-data/homebrew tools
├── packaging/homebrew/      # appcleaner.rb source formula (tap copy is auto-updated)
└── docs/                    # plan.md (design/safety, section refs used in code), ui-ux.md (screens S1..S10), development.md, packages.md, qa-report.md
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Build/test/l10n/helper/Sentinel how-to | `docs/development.md` | Canonical dev guide; read before cross-target changes |
| Product & safety rationale | `docs/plan.md` | Code comments cite its section numbers (4.x, 5.x, 8.2) |
| Screen behavior | `docs/ui-ux.md` | S1..S10 IDs used in code/comments |
| CLI subcommands | `Sources/appcleaner/Arguments.swift` | scan, remove, orphans [clean], packages [remove/caches [clean]], history, restore, help, version |
| CLI strings | `Sources/CleanerCore/Resources/Localization/<lang>.lproj/CLI.strings` | `t("…")`, `UsageError("…")`; usage text = `ko.lproj` key `"usage"` |
| Sentinel strings | same dir, `Sentinel.strings(.dict)` | `S("…")` |
| `.app` assembly, plists, signing, login item/daemon placement | `scripts/build-app.sh` | Not a SwiftPM product; manual bundle |
| Release artifacts | `scripts/package-release.sh`, `.github/workflows/release.yml` | `v*` tag -> DMG/ZIP/CLI tar + SHA256SUMS, prerelease |
| Homebrew tap update | `scripts/update-homebrew-formula.sh`, `packaging/homebrew/appcleaner.rb` | Needs `HOMEBREW_TAP_TOKEN` secret, else skipped |
| Cask zap snapshot / rule signing | `scripts/update-homebrew-snapshot.py`, `scripts/sign-rule-data.swift` | keygen/pubkey/sign/verify |

## CODE MAP
Refs = whole-word matches across tracked `*.swift` (`git grep -wc`), not semantic references.

| Symbol | Type | Location | Refs | Role |
|--------|------|----------|------|------|
| `Candidate` | struct | `CleanerCore/Models/` | 303 | One removable path + classification |
| `EngineText` | struct | `CleanerCore/Models/EngineText.swift` | 284 | Localizable engine message (key/args/parts) |
| `Fixture` | class | `CleanerTestSupport/Fixture.swift` | 175 | Temp fake filesystem for tests |
| `SystemPaths` | struct | `CleanerCore/Environment/` | 86 | Injected root/home paths |
| `AppLanguage` | enum | `CleanerCore/Localization/` | 79 | ko/en/ja selection + locale |
| `SafetyGuard` | struct | `CleanerCore/Safety/SafetyGuard.swift` | 70 | Protected-path gate |
| `CleanupPlan` | struct | `CleanerCore/Models/` | 66 | Executable selection |
| `AppIdentity` | struct | `CleanerCore/Models/` | 55 | Resolved app (BID, name, team) |
| `AppModel` | class | `AppCleanerGUI/Models/AppModel.swift` | 38 | GUI root state |
| `CommandRunning` | protocol | `CleanerCore/Environment/` | 36 | External command seam |
| `CleanerEngine` | protocol | `CleanerCore/Contracts/CleanerEngine.swift` | 25 | Facade used by GUI/CLI/demo |
| `LiveCleanerEngine` | class | `CleanerCore/Engine/LiveCleanerEngine.swift` | 4 | Production composition root |

## CONVENTIONS
- Swift Testing only (`import Testing`, `@Test`, `#expect`); never XCTest.
- Engine code never uses `/` or `NSHomeDirectory()` directly; inject `SystemPaths`.
- External commands only via `CommandRunning` with argv arrays; no shell-string assembly.
- Tests create/delete files only inside `Fixture` temp trees; never touch real home, `/Library`, or Trash.
- Shared types in `CleanerCore/Models` and `Contracts`: additive changes only (GUI, CLI, Sentinel, helper, JSON history all depend on them).
- User-visible text: the Korean source string is the key, and en + ja translations are added in the same change. Supported: ko, en, ja; fallback is English. Default package localization is `ko`; `CFBundleDevelopmentRegion` is `en`.
- `.strings` + `.stringsdict` only (CLT lacks `xcstringstool`, so no String Catalogs).
- Adding a language: `AppLanguage` case, GUI + CleanerCore `.lproj` files, `LANGUAGES` in `build-app.sh`, `--lang` list in the usage text.
- Branches: `main` = release, `dev` = integration, `feature/*` from `dev` -> PR.

## ANTI-PATTERNS (THIS PROJECT)
- Shipping a `HELPER_DEV=1` build: the helper then accepts any client with a matching identifier, regardless of Team ID.
- Committing the private key from `sign-rule-data.swift keygen`.
- Hand-editing the Homebrew tap's `Formula/appcleaner.rb`; edit `packaging/homebrew/appcleaner.rb`.
- Using `swift run` to test login items or the helper: registration only works from the `.app` bundle.
- Test app bundle IDs under `com.dallisoft.*`: same-vendor rules demote them (orphan confidence and "shared" LaunchAgents).

## COMMANDS
```bash
swift build
./scripts/test.sh                                   # all tests (adds CLT Testing plugin path); run before every PR
./scripts/test.sh --filter OrphanScannerTests
APPCLEANER_PERF=1 ./scripts/test.sh --filter slackLikeEndToEnd   # perf target
./scripts/build-app.sh                              # -> dist/App Cleaner.app (ad-hoc, Hardened Runtime)
open -n "dist/App Cleaner.app" --args --demo        # in-memory demo, safe
VERSION=0.3.2 ./scripts/package-release.sh
# build-app.sh env: CONFIG ARCH VERSION BUILD_NUMBER BUNDLE_ID SIGN_IDENTITY TEAM_ID HELPER_DEV
```

## NOTES
- No CI test job: the release workflow only builds and uploads. Local `./scripts/test.sh` is the gate.
- Official releases are ad-hoc signed and never notarized, so the helper never accepts connections and admin work falls back to `AppleScriptAdminExecutor` + `privileged-op.sh` (password prompt, up to 2x per batch).
- Version bump: `Sources/appcleaner/CLI.swift` literal + `VERSION=` passed to the scripts/tag. `CFBundleVersion` = `git rev-list --count HEAD`.
- Sentinel dev run without touching settings: run the bundled binary with `--log-only --watch-trash --trash /tmp/fake-trash` or `--log-only --scan-now`.
- Re-registering Sentinel after a rebuild can fail (`needs LWCR update`, #50); toggling it off and on in S7 fixes it.
