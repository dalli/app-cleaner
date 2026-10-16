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

> **App Cleaner is not notarized by Apple.** The source is public, and this repository's GitHub Actions builds ad-hoc signed
> binaries from it and publishes them on [Releases](https://github.com/dallisoft/app-cleaner/releases)
> ([`release.yml`](.github/workflows/release.yml); build logs are in the Actions tab).
> Because of that, macOS Gatekeeper blocks the first launch. Follow [First launch](#first-launch--allow-it-in-gatekeeper) below to allow it **once**.
> If you would rather not run prebuilt binaries, [build it yourself](#build), or install the CLI with Homebrew (built from source).

### Files

| File | Contents |
|---|---|
| `AppCleaner-<version>-macos-arm64.dmg` | **The app (recommended)** — open it and drag App Cleaner to Applications |
| `AppCleaner-<version>-macos-arm64.zip` | The app (same as the DMG) |
| `appcleaner-<version>-macos-arm64.tar.gz` | Standalone CLI (keep `AppCleaner_CleanerCore.bundle` next to the executable) |
| `SHA256SUMS.txt` | SHA-256 of the files above |

Check that what you downloaded matches the release (recommended):

```sh
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt --ignore-missing   # OK for each downloaded file
```

### Install

1. Open the DMG and **drag App Cleaner to the Applications folder** (for the zip, move the extracted app to Applications).
2. Launch it **from Applications**. If you open it straight from the DMG window or your Downloads folder, macOS runs it from a temporary location (App Translocation).

### First launch — allow it in Gatekeeper

The first time you open it, macOS shows a warning and does not run the app. This is expected for an app that is not notarized:
**“App Cleaner” Not Opened** — Apple could not verify “App Cleaner” is free of malware… with **Done** and **Move to Trash** buttons
(the wording may differ slightly between macOS versions).

Click **Done** (not Move to Trash), then use one of these:

**Option 1 — System Settings (no Terminal)**

1. Open **System Settings › Privacy & Security** and scroll down to the **Security** section.
2. Next to “App Cleaner” was blocked to protect your Mac, click **Open Anyway**.
   The button only appears for about an hour after you try to open the app — if it is missing, open the app once more and check again.
3. Confirm with your password or Touch ID.
4. If another confirmation appears, click **Open Anyway**. From then on the app opens normally.

**Option 2 — Terminal (one line)**

```sh
xattr -dr com.apple.quarantine "/Applications/App Cleaner.app"
open "/Applications/App Cleaner.app"
```

`xattr -dr` removes the “quarantine” flag that macOS adds to downloaded files — **for this app only**. It does not change the app's
signature or your Mac's Gatekeeper settings, and `sudo` is usually not needed. The app then opens without the prompt and without App Translocation.

Good to know

- Either way, the approval also covers **Sentinel (the menu bar Trash monitor) and the CLI (`Contents/Helpers/appcleaner`) inside the app**.
- On macOS 14 (Sonoma) you can also Control-click the app in Finder › **Open** › **Open**. From macOS 15 on this no longer works; use the options above.
- The approval applies to that version (code) only. **After updating to a new version, allow it once more.**
- If you see “App Cleaner” is damaged and can't be opened, the download is broken or the signature was damaged while extracting.
  Check the checksums, download again and install from the DMG; if it still happens, use Option 2.

### After the first launch

- Grant App Cleaner **Full Disk Access** as the onboarding screen suggests (System Settings › Privacy & Security › Full Disk Access).
  It is needed to read other apps' containers, and the Trash monitor (Sentinel) uses the same permission — Sentinel is not listed separately.
- Turning on Settings › Trash monitoring or scheduled scan alerts registers Sentinel as a login item. macOS shows a notification that App Cleaner
  can run in the background, and asks whether to allow notifications from “App Cleaner Sentinel”.
- Administrator operations (cleaning or restoring items in system folders) ask for your administrator password. The privileged helper only works in
  Developer ID–signed builds, so official releases do not use it.

### Updating and uninstalling

- **Update**: replace the app in Applications with the new DMG, then do [First launch](#first-launch--allow-it-in-gatekeeper) again.
  If you use Trash monitoring and the Sentinel icon is missing from the menu bar afterwards, turn Trash monitoring (and scheduled scan alerts) off and on again in Settings (#50).
- **Uninstall**: turn off Trash monitoring and scheduled scan alerts in Settings (this removes the login item), then move App Cleaner to the Trash.

### Installing the CLI

**Homebrew (recommended — no approval needed)**

```sh
brew install dallisoft/tap/appcleaner
appcleaner version
```

The formula builds from source on your Mac (requires Command Line Tools or Xcode with Swift 6), so Gatekeeper does not block it. Update with `brew upgrade appcleaner`.

**tar.gz (standalone CLI)**

```sh
cd ~/Downloads
tar -xzf appcleaner-<version>-macos-arm64.tar.gz
xattr -dr com.apple.quarantine appcleaner-<version>-macos-arm64   # clears the quarantine flag for this folder only
./appcleaner-<version>-macos-arm64/appcleaner version
```

Without clearing the quarantine flag, macOS shows “appcleaner” Not Opened and does not run it. Files downloaded with `curl -LO` instead of a browser are not quarantined.
If you installed the app, you can also use `"/Applications/App Cleaner.app/Contents/Helpers/appcleaner"` directly.

### Publishing a release (maintainers)

Pushing a `v*` tag makes GitHub Actions (`.github/workflows/release.yml`) build on a macOS arm64 runner and upload the artifacts. Tests are run locally with
`./scripts/test.sh` before opening a PR (there is no CI). To package locally: `VERSION=0.1.1 ./scripts/package-release.sh`.

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
  A privileged helper (LaunchDaemon, XPC, file-descriptor-based moves) is included but only works in builds signed with a Team ID. Official releases are ad-hoc signed and use the password prompt;
  if you build with your own Developer ID, you can install the helper in Settings ([docs/development.md](docs/development.md), section “권한 헬퍼”).

## Current status (v0.3.x)

Covers Phases 1a, 1b, 2, and 3 of plan.md. Remaining work is tracked in [issues labeled `backlog`](https://github.com/dallisoft/app-cleaner/issues?q=is%3Aissue+is%3Aopen+label%3Abacklog).

- Phase 3: Trash monitoring and scheduled orphan scans (Sentinel, #18), privileged helper (#17 — not used in official releases)
- Distribution: **no notarization or Developer ID signing** (see [First launch](#first-launch--allow-it-in-gatekeeper)). Evaluating Sparkle auto-updates (#48), Homebrew CLI tap (#15), rotating the rule-data signing key (#20)
- VM and real-device QA matrix (#21), GUI gaps (#22)
- Localization: the GUI and CLI support Korean, English, and Japanese (English for any other language). Japanese UI review and translation proofreading: #27
- Cleaning up CLI tools installed with a package manager (npm, cargo, pipx, uv), their data and caches: CLI only — [docs/packages.md](docs/packages.md) (#39)

## Feedback

- Please report bugs and suggest features in [Issues](https://github.com/dallisoft/app-cleaner/issues). Including your macOS version and App Cleaner version (`appcleaner version`) helps.
- This repository **does not accept outside pull requests** (only maintainers can open them). Please describe fixes in an issue instead.
