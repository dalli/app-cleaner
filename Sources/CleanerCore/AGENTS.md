# CleanerCore

## OVERVIEW
UI-agnostic engine shared by GUI, CLI, Sentinel, and the privileged helper (score ~17: 71 Swift files, 20+ subdirs, ~1k public decls, bundled resources). Its own file because every safety invariant lives here.

## PIPELINES
- **App removal scan** (`Scanning/AppScanner.swift`): `IdentityResolver` -> parallel `CandidateSource`s (path rules -> launch plists -> receipts -> Homebrew zap) -> merge/dedupe -> `SafetyGuard` -> `DataNatureClassifier` -> `SelectionPolicy` -> sizes -> `ScanReport`.
- **Cleanup** (`Execution/`): `CleanupPlanner` (selection -> `CleanupPlan`) -> `CleanupExecutor`: stop services -> terminate processes -> flush prefs -> re-check safety -> move (Trash, or holding folder via admin path) -> post-process. Journals incrementally; one item's failure does not roll back others.
- **Restore / history** (`Journal/JournalStore.swift`): reverse-order restore, never overwrites a conflict; holding-folder purge.
- **Orphans** (`Orphan/`, `OrphanCollector.swift` 545 lines) and **packages** (`Packages/`, npm/cargo/pipx/uv — see `docs/packages.md`) are separate scan->plan paths reusing Safety/Selection.
- Composition root: `Engine/LiveCleanerEngine.swift`. Facade protocol: `Contracts/CleanerEngine.swift`; component protocols: `Contracts/Components.swift`.

## WHERE TO LOOK
| Task | Location |
|------|----------|
| Shared models (`Candidate`, `AppIdentity`, `CleanupPlan`, `JournalSession`, `ScanReport`) | `Models/` |
| User-facing engine text / keys | `Models/EngineText.swift` (596 lines; `Key.rawValue` + `koreanFormat`) |
| Paths, command runner, code signature, resource lookup | `Environment/` (`SystemPaths`, `CommandRunning`, `BundledResources`) |
| Protected paths | `Safety/SafetyGuard.swift` |
| BID / name matching | `Discovery/` (`MatchingSupport.swift`, `BundleIDRules`) |
| Admin execution, fallback script | `Mover/` (`PrivilegedScript.swift`, `Resources/Scripts/privileged-op.sh`) |
| Helper XPC, command validation, fd moves | `Privileged/` (`PrivilegedCommandProcessor`, `SecureFileOperations`) |
| Rule data load / signed update | `Contracts/RuleData.swift`, `RuleUpdate/` (`RuleDataVerifier`, `RuleDataStore`) |
| Sentinel decision logic (testable part) | `Sentinel/` (`TrashSnapshot`, `PeriodicScanSchedule`, `SentinelLink`) |
| Language choice / translation tables | `Localization/` (`AppLanguage`, `Translations`) |

## INVARIANTS (do not weaken)
- Protected/synced (unselectable) candidates are **never** put in a plan (`CleanupPlanner.swift:8`).
- `SafetyGuard` checks both the input path and the parent-resolved realpath, at scan time **and** again right before each move.
- BID prefix matching is dot-boundary only; name matching is exact, case-insensitive (`MatchingSupport.swift`).
- Helper accepts only the six `AdminOperation` kinds; fixed tool paths + argv arrays; labels/package IDs `[A-Za-z0-9._-]`, no `com.apple.*`, never this app or its helper. It re-validates everything and never trusts the app's judgment.
- Privileged moves are fd-relative: `openat(O_NOFOLLOW|O_DIRECTORY)` descent, root-owned allow-roots, `renameatx_np(RENAME_EXCL)`; holding dirs are root-owned 0700.
- After a request is sent to the helper, a dropped connection is recorded as failure (`helper-no-reply`) — never re-sent through the fallback path (prevents double moves).
- `privileged-op.sh` is hash-checked by `PrivilegedScript`; editing it requires updating that hash.
- Rule-data updates: Ed25519 manifest signature + per-file SHA-256, no downgrade, staged then atomically swapped. The embedded public key is a dev key (#20).

## CONVENTIONS
- Find resources through `BundledResources` / `Translations` / `BundledRuleData` (they resolve symlinked CLI installs such as Homebrew); never add new direct `Bundle.module` lookups.
- Engine strings: add an `EngineText.Key` with its Korean format, then add it to `Resources/Localization/{en,ja}.lproj/Engine.strings`. Nest messages through `EngineText(..., parts:)`, never string concatenation. Korean particles only via `subjectParticleOnFirstArg`.
- `--json` output carries Korean `text` plus `key`/`args`/`parts`; keep these fields backward compatible.

## TESTS
`Tests/CleanerCoreTests` + `Sources/CleanerTestSupport` (`Fixture` temp trees, `StubCommandRunner`, `StubSignatureReader`). `PrivilegedHelperTests` (628 lines) runs the helper processor as a normal user on fixture roots, including symlink-swap race loops. Fixture paths live under `/var/folders` while the engine resolves them to `/private/var/folders`, so compare paths after realpath.
