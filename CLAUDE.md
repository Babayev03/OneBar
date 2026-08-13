# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

OneBar is a macOS menubar utility (SwiftPM executable, Swift 6 toolchain in Swift 5 language mode, macOS 26+). It bundles clipboard history with on-device OCR/QR, system stat rings, system-wide keyboard cleaning, prevent-sleep, and screen-region text/QR scanning. No third-party dependencies, no network calls — everything is AppKit/SwiftUI/Vision/IOKit/Carbon.

There is no test target and no linter config.

## Commands

```sh
swift build                 # debug build
swift build -c release      # release build
./build-app.sh              # release build → assemble dist/OneBar.app → ad-hoc sign → install to /Applications → relaunch
```

`build-app.sh` is the only way to actually *run* the app: the binary needs the `Bundle/Info.plist` (`LSUIElement`, bundle ID `com.ilham.onebar`) to behave as a menubar accessory. The bundle ID is deliberately stable so the Accessibility/TCC grant survives rebuilds — do not change it casually or the user must re-grant permissions.

Regenerating the icon (rarely needed):

```sh
swift scripts/make-icon.swift
iconutil -c icns build/AppIcon.iconset -o Bundle/AppIcon.icns
```

## Architecture

`Sources/OneBar/` splits into `Services/` (behavior + state, all singletons), `Views/` (SwiftUI), and `Support/` (models, helpers).

**Everything is a `@MainActor` singleton.** Services are `static let shared` and most are `@Observable`, so views read them directly (`AppState.shared`, `SystemStatsService.shared`) rather than via `@EnvironmentObject`. The package builds with `-parse-as-library`.

**Two scenes, plus manually-managed windows.** `OneBarApp` declares a `MenuBarExtra` (`.window` style → `MenuView`) and a `Window(id: "preferences")` with `.defaultLaunchBehavior(.suppressed)`. Everything else — the clipboard panel, the keyboard-cleaning overlay, the HUD pill, the prevent-sleep status item — is an `NSPanel`/`NSWindow`/`NSStatusItem` created imperatively by its owning service. `AppDelegate` wires startup (start polling, start stats, register hotkey) and teardown.

**Settings live in `AppState`,** an `@Observable` singleton where every property has a `didSet` that writes to `UserDefaults` and defaults come from `defaults.register`. Adding a preference means: property + `didSet` + entry in the `register(defaults:)` dictionary + read in `init`. Changing a setting does not itself re-configure services — the Preferences panes call the side effect explicitly (e.g. `SystemStatsService.shared.restart()` after `statsInterval`, `startPolling()`/`stopPolling()` after the clipboard toggle). `keyboardCleaningActive`/`preventSleepActive` are intentionally *not* persisted.

**Clipboard pipeline:** `ClipboardManager` polls `NSPasteboard.general.changeCount` every 0.5s, skips concealed/transient/auto-generated pasteboard markers and ignored source apps, dedupes identical text to the top, then enforces `maxImages` and `historyCap` (pinned items are exempt from both). Images are written as PNG files by `ClipboardStore` into `~/Library/Application Support/OneBar/images/`; `history.json` holds the metadata. OCR + QR run afterwards via `ImageAnalysisService` (Vision, off the main thread) and are patched back onto the item by id, so a `ClipboardItem` is mutable after insertion.

**Boot-scoped history:** `ClipboardStore` stamps `kern.boottime` (`BootTime.timestamp`) into `history.json`; on load, a boot-time mismatch beyond 5s drops all unpinned items and their image files. Pinned items always survive. This is the reason history "clears on restart".

**Clipboard panel keyboard model:** `ClipboardPanelController` owns a borderless non-activating `KeyablePanel` and installs three `NSEvent` monitors while visible — a local `keyDown` monitor (`handle(_:)` returns true to swallow the event), plus global and local mouse-down monitors for click-outside dismissal. `handle(_:)` branches on `isEditingSearch` (first responder is an `NSTextView`): bare-key bindings only apply when *not* typing. Esc unwinds one layer at a time: preview → action popup → search focus → hide. Selection/search/filter state lives in `ClipboardPanelModel`; `PanelAction.actions(for:)` derives the action list from the item's kind and whether OCR/QR/URL data is present.

**Shortcuts:** `ShortcutStore` maps `ShortcutAction` → `KeyBinding` (raw `keyCode` + modifier mask), persisted as JSON. Only `openPanel` is global — it goes through `HotkeyManager`, which uses Carbon `RegisterEventHotKey` (permission-free); every other binding is matched inside the panel's local monitor. Rebinding `openPanel` re-registers the Carbon hotkey immediately.

**Permission-gated features:** keyboard cleaning (a `.cghidEventTap` `CGEvent.tapCreate` swallowing key events plus the `NX_SYSDEFINED` hardware-button subtypes — volume/brightness/media/eject/power — behind a `.screenSaver`-level overlay per screen; Touch ID is unaffected because fingerprint reads never produce a CGEvent) and pasting (`PasteService` synthesizes ⌘V via `CGEvent`) both require Accessibility and check `AXIsProcessTrusted()`; both degrade quietly rather than erroring. Scan Text/QR shells out to `/usr/sbin/screencapture -i -c` and needs Screen Recording — the `Process` must be retained in `ScreenCaptureService.runningProcess`, since a still-running deallocated `Process` crashes the app.

**Menubar label:** `MenuBarExtra` mangles stacked/inline views in its label, so the live CPU/MEM readout is pre-rendered to a single template `NSImage` via `ImageRenderer` in `MenuBarLabel.statsImage`.

## Conventions

- Use `.liquidGlass(in:)` (`Support/LiquidGlass.swift`) for glass surfaces rather than calling `glassEffect`/`.ultraThinMaterial` directly — it holds the macOS 26 availability fallback in one place.
- Transient user feedback goes through `HUD.show(_:symbol:)`, not alerts.
- Timers are created with `Timer(...)` + `RunLoop.main.add(timer, forMode: .common)` so they keep firing during menu tracking; callbacks hop back with `Task { @MainActor in ... }`.
- Comments in this codebase explain *why* a non-obvious workaround exists (AppKit quirks, permission behavior). Match that — don't add narration of what the code plainly does.
