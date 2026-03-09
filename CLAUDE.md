# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Build & Run Commands

All common tasks are in the Makefile:

```bash
make build          # Debug build
make release        # Release build
make run            # Build + kill existing + launch app
make rerun          # Kill + relaunch (no rebuild)
make kill           # Kill running app
make clean          # Clean build artifacts
```

Direct xcodebuild: `xcodebuild -scheme HangulJaso -configuration Debug build`

## Architecture

macOS menu bar app (SwiftUI `MenuBarExtra`) with no Dock icon (`LSUIElement = true`).

**App entry:** `HangulJasoApp` creates a `MenuBarExtra` (popover window) and a separate `Window` for the main interface. A single `HangulJasoViewModel` (`@Observable`, `@MainActor`) is shared via SwiftUI `.environment()`.

**Data flow:**
- `HangulJasoViewModel` is the central state holder — owns all services
- `NFCService` handles NFD detection and NFC conversion of filenames
- `FileMonitorService` uses FSEvents for folder watching
- `HistoryService` persists conversion history to JSON in Application Support
- `WorkflowInstaller` manages Finder Quick Action installation

**Key conventions:**
- Version is stored in `HangulJaso/Resources/Info.plist` (`CFBundleShortVersionString`)
- Settings stored in `UserDefaults` with keys in `Constants.UserDefaultsKeys`
- NFC conversion uses `String.precomposedStringWithCanonicalMapping` (Swift native)
- NFD detection: `name != name.precomposedStringWithCanonicalMapping`
- No test target; verify by building and running
- Use XcodeGen (`project.yml`) to generate .xcodeproj — do not commit .xcodeproj
