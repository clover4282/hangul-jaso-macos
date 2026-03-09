# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Build & Run Commands

All common tasks are in the Makefile:

```bash
make build          # Debug build
make install        # Build + install to /Applications
make run            # Build + install + launch app
make rerun          # Kill + relaunch (no rebuild)
make kill           # Kill running app
make clean          # Clean build artifacts
make release        # Release build
```

Direct xcodebuild: `xcodebuild -scheme HangulJaso -configuration Debug build`

**Important:** Always use `make run` (not `make build` + manual open) to ensure the app runs from `/Applications`. This is required for URL schemes and Finder Quick Actions to work correctly.

## Architecture

macOS menu bar app (SwiftUI `MenuBarExtra` with `.menu` style) with no Dock icon (`LSUIElement = true`).

**App entry:** `HangulJasoApp` creates a `MenuBarExtra` (dropdown menu with "설정 열기" and "종료") and a separate `Window` for the settings interface. A single `HangulJasoViewModel` (`@Observable`, `@MainActor`) is shared via SwiftUI `.environment()`.

**Data flow:**
- `HangulJasoViewModel` is the central state holder — owns all services
- `NFCService` handles NFD detection and NFC conversion of filenames
- `FileMonitorService` uses FSEvents for folder watching (recursive subdirectory support)
- `WorkflowInstaller` manages Finder Quick Action installation (auto-installs on app launch)
- `AppDelegate` handles NFD file tagging, URL scheme processing, and Finder extension communication

**Key conventions:**
- Version is stored in `HangulJaso/Resources/Info.plist` (`CFBundleShortVersionString`)
- Settings stored in `UserDefaults` with keys in `Constants.UserDefaultsKeys`
- NFC conversion uses `String.precomposedStringWithCanonicalMapping` (Swift native)
- NFD detection: `name != name.precomposedStringWithCanonicalMapping`
- No test target; verify by building and running
- Use XcodeGen (`project.yml`) to generate .xcodeproj — do not commit .xcodeproj
- Code signing: `DEVELOPMENT_TEAM: 9P8DG7976Y`, `CODE_SIGN_IDENTITY: Apple Development`
- Default watched folders (Downloads, Desktop, Documents) added on first launch
