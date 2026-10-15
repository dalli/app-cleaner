[한국어](README.md) | **English** | [日本語](README.ja.md)

# App Cleaner (working title)

A tool that removes macOS apps along with their leftovers — **safely and reversibly**. It can also find and clean up orphaned leftovers from apps you have already deleted.

- Design: [docs/plan.md](docs/plan.md), [docs/ui-ux.md](docs/ui-ux.md)
- Development: [docs/development.md](docs/development.md)

Requirements: macOS 14 or later, Swift 6 (Command Line Tools or Xcode).

## Build

```sh
./scripts/build-app.sh                 # dist/App Cleaner.app (ad-hoc signed)
open "dist/App Cleaner.app"            # real engine
open -n "dist/App Cleaner.app" --args --demo   # preview the UI with fake data
./scripts/test.sh                      # tests
```

## Install (Apple Silicon)

Download from [Releases](https://github.com/dallisoft/app-cleaner/releases).

- `AppCleaner-<version>-macos-arm64.zip` — the app (the CLI is at `Contents/Helpers/appcleaner`)
- `appcleaner-<version>-macos-arm64.tar.gz` — standalone CLI (keep `AppCleaner_CleanerCore.bundle` next to the executable)

Builds are ad-hoc signed and not notarized, so if Gatekeeper blocks the first launch, right-click the app in Finder and choose Open.
Releases are published by GitHub Actions (`.github/workflows/release.yml`) when a `v*` tag is pushed: it builds and tests on a macOS arm64 runner, then uploads the artifacts.
To package locally: `VERSION=0.1.1 ./scripts/package-release.sh`.

## CLI

```sh
appcleaner scan "/Applications/Foo.app"          # inspect only (deletes nothing)
appcleaner remove Foo --dry-run                  # cleanup plan as JSON
appcleaner remove Foo                            # confirm, then move to Trash / holding folder
appcleaner orphans --min-confidence medium       # scan for orphaned leftovers
appcleaner orphans clean --dry-run               # orphan cleanup plan (default: high confidence + not user data)
appcleaner packages                              # CLI tools installed with npm/cargo/pipx/uv + data with the same name
appcleaner packages remove <name> --dry-run      # plan to remove a CLI tool (--with-data: its data too)
appcleaner packages caches clean --dry-run       # plan to clean package manager download caches
appcleaner history                               # removal history
appcleaner restore <session ID>                  # undo
```

The CLI is `Contents/Helpers/appcleaner` inside the `.app` bundle.

The output language (Korean, English, Japanese) is chosen from `--lang <ko|en|ja>` → `APPCLEANER_LANG` → `LC_ALL`/`LC_MESSAGES`/`LANG` → the system language, falling back to English for unsupported languages. `--json` output is the same in every language.

## Safety principles

- Nothing is permanently deleted: user files go to the Trash, root-owned files go to a holding folder (`/Library/Application Support/AppCleaner/Holding`), and everything can be restored from the removal history.
- Low-confidence items, items shared with other apps, and user data are never selected by default. iCloud data, device backups, `~/.ssh`, and similar paths cannot be selected at all.
- Privileged operations run only the bundled fixed script (`privileged-op.sh`, hash-verified), and paths are re-validated on the elevated side.

## Current status (v0.1.x — MVP)

Covers Phases 1a, 1b, and 2 of plan.md. Remaining work is tracked in [issues labeled `backlog`](https://github.com/dallisoft/app-cleaner/issues?q=is%3Aissue+is%3Aopen+label%3Abacklog).

- Phase 3: replace the admin path with a privileged helper — resolving the TOCTOU limitation of the current path (#17); Trash monitoring and scheduled orphan scans (#18)
- Phase 4: Developer ID signing and notarization, Sparkle (#19), Homebrew tap and cask (#15, #16), rotating the rule-data signing key (#20)
- VM and real-device QA matrix (#21), GUI gaps (#22)
- Localization: the GUI and CLI support Korean, English, and Japanese (English for any other language). Japanese UI review and translation proofreading: #27
- Cleaning up CLI tools installed with a package manager (npm, cargo, pipx, uv), their data and caches: CLI only — [docs/packages.md](docs/packages.md) (#39)
