# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Build & Run Commands

All common tasks are in the Makefile:

```bash
make build          # xcodegen + Debug build
make install        # Build + install to /Applications
make run            # Build + install + launch app
make rerun          # Kill + relaunch (no rebuild)
make kill           # Kill running app
make clean          # Clean build artifacts
make release        # Release build
```

Direct xcodebuild: `xcodebuild -scheme HangulJaso -configuration Debug build`

**Important:** Always use `make run` (not `make build` + manual open) to ensure the app runs from `/Applications`. This is required for URL schemes, Finder Quick Actions, and Finder Sync Extension to work correctly.

**Important:** `make build` automatically runs `xcodegen generate` before building. After modifying `project.yml`, no separate xcodegen step is needed.

## Architecture

macOS menu bar app (SwiftUI `MenuBarExtra` with `.menu` style) with no Dock icon (`LSUIElement = true`).

**App entry:** `HangulJasoApp` creates a `MenuBarExtra` (dropdown menu with "설정 열기" and "종료") and a separate `Window` for the settings interface. A single `HangulJasoViewModel` (`@Observable`, `@MainActor`) is shared via SwiftUI `.environment()`.

**Targets:**
- `HangulJaso` — main app
- `HangulJasoFinder` — Finder Sync Extension (app-extension, embedded in main app's PlugIns/)

**Data flow:**
- `HangulJasoViewModel` is the central state holder — owns all services
- `NFCService` handles NFD detection and NFC conversion of filenames
- `FileMonitorService` uses FSEvents for folder watching (recursive subdirectory support)
- `WorkflowInstaller` manages Finder Quick Action installation (auto-installs on app launch)
- `LaunchAgentService` manages LaunchAgent plist for auto-start and KeepAlive (auto-restart on crash)
- `AppDelegate` handles NFD file tagging, URL scheme processing, auto-convert notifications, and Finder extension communication via `DistributedNotificationCenter`
- `FinderSyncExtension` provides Finder context menu and toolbar item, sends convert requests to main app via `DistributedNotificationCenter`

**Key conventions:**
- Version is stored in `HangulJaso/Resources/Info.plist` (`CFBundleShortVersionString`)
- Settings stored in `UserDefaults` with keys in `Constants.UserDefaultsKeys`
- NFC conversion uses `String.precomposedStringWithCanonicalMapping` (Swift native)
- NFD detection: `name != name.precomposedStringWithCanonicalMapping`
- Low-level NFD detection uses `readdir()` to get raw filenames (Swift URL auto-normalizes NFD→NFC)
- No test target; verify by building and running
- Use XcodeGen (`project.yml`) to generate .xcodeproj — do not commit .xcodeproj
- Code signing: `DEVELOPMENT_TEAM: 9P8DG7976Y`, `CODE_SIGN_IDENTITY: Apple Development`
- FinderSync Extension requires App Sandbox entitlement to register with pluginkit
- Default watched folders (Downloads, Desktop, Documents) added on first launch

**Scan triggers (auto-convert):**
- App launch: full recursive scan of all auto-convert folders
- FSEvents: real-time file change detection → rescan affected directory
- Periodic: 1-hour interval full scan of auto-convert folders
- Folder add: immediate full scan when user adds a watched folder
- `HangulJasoRescanDirectory` / `HangulJasoFullScanDirectory` notifications coordinate between ViewModel and AppDelegate

**CPU optimization notes:**
- Single `opendir`/`readdir` pass for both NFD detection and NFC conversion (no separate scan+convert)
- `removeTag` only called on files that actually had NFD tags (not all NFC files)
- `isScanning` flag prevents concurrent scan overlap
- Deduplication: FSEvents batched by parent directory to avoid redundant rescans
