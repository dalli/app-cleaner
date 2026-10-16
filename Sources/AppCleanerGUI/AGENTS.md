# AppCleanerGUI

## OVERVIEW
SwiftUI front end over `CleanerCore` (score ~12: 37 files, 10 subdirs, own resources/localization, demo engine) — distinct UI domain.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Entry, launch args, engine choice | `App/AppCleanerApp.swift`, `EngineFactory.swift` | `@main`; `--demo*` args pick `DemoCleanerEngine` + in-memory settings |
| App-wide state / routing | `Models/AppModel.swift` | Coordinates list, inspector, cleanup, history, orphans; `handleOpen` takes `com.dallisoft.appcleaner://` links from Sentinel |
| Per-screen state | `Models/` (`AppListViewModel`, `InspectorViewModel`, `CleanupFlowModel`, `HistoryViewModel`, `OrphanViewModel`, `SelectionTree`) | `@MainActor @Observable` |
| Screens | `Views/` (`InspectorView` 540+ lines, `OrphansView`, `HistoryView`), `Views/Components/` | Screen IDs S1..S10 follow `docs/ui-ux.md` |
| Settings S7, Sentinel login item, helper install | `Support/SentinelService.swift`, `Support/AppSettings.swift`, `Views/SettingsView.swift`; helper installer from `EngineFactory.swift` | `SMAppService`; tests/demo use in-memory implementations |
| Strings | `Support/L10n.swift`, `Resources/{en,ja,ko}.lproj/Localizable.{strings,stringsdict}` | |
| Demo / screenshots | `Demo/` (`DemoCleanerEngine`, `DemoData`, `DemoHelperInstaller`) | Fully in-memory; never touches real files |

## CONVENTIONS
- **No SwiftUI `@State`/`@StateObject` for model state**: on the macOS 27 SDK `@State` is a macro and CLT lacks the SwiftUIMacros plugin. Keep all state in `@Observable` view models; `App` holds `AppModel` as a plain `let`.
- Strings: `L("Korean source text")` / `L("파일 %lld개", n)`. The Korean text **is** the key; `ko.lproj/Localizable.strings` stays empty. Add every new key to the `en` and `ja` `.strings` (or `.stringsdict` for counts; ja uses `other` only; a key must not be in both files).
- Format specifiers: `%@` / `%lld` in the key; reorder with `%2$@`. Count, kind, and order must match the source.
- Korean particles only via `Josa` (`Support/Format.swift`); never in en/ja text. Internal terms (bootout, cfprefsd) appear only in the "information source" field.
- Language = first supported entry in `Locale.preferredLanguages`, else English (`AppLanguage.preferred(from:)`). Do not use `Bundle.preferredLocalizations` (returns dev language ko).
- Engine-originated text is `EngineText`, translated by CleanerCore resources — do not re-translate it here.
- Demo mode must use `AppSettings.inMemory()` and `InMemorySentinelService` so it never alters real settings or login items.

## ANTI-PATTERNS
- Calling real filesystem / `SMAppService` paths from tests — use `fastEngine()` and the in-memory services.
- Adding a user-visible string without en+ja translations — `LocalizationTests` fails on missing/unused keys, specifier mismatch, or Hangul inside a translation.
- String Catalogs (`.xcstrings`) — CLT has no `xcstringstool`.

## TESTS
`Tests/AppCleanerGUITests` (Swift Testing). Helpers in `TestSupport.swift`: `fastEngine()` (zero-delay demo engine), `CountingEngine`, `waitUntil(timeout:)` (bounded condition wait, 30s default — no fixed sleeps).
