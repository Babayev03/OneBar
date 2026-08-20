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

`build-app.sh` is the only way to actually *run* the app: the binary needs the `Bundle/Info.plist` (`LSUIElement`, bundle ID `com.onebar.app`) to behave as a menubar accessory.

The script signs ad-hoc but passes an explicit `-r='designated => identifier "..."'`. Without it codesign derives a designated requirement that pins the cdhash, which changes on every build — TCC then fails the app's Accessibility check while System Settings still shows the toggle on, so the permission-gated features die silently and `AXIsProcessTrustedWithOptions` won't even re-prompt (the stale row already exists, and the prompt only appears when there is none). Naming the bundle ID keeps the requirement identical across rebuilds, so the grant survives. The bundle ID is read out of `Info.plist` rather than repeated in the script; changing it still costs a one-time `tccutil reset Accessibility <id>` plus a re-grant, and moves the `UserDefaults` domain.

Regenerating the icon (rarely needed):

```sh
swift scripts/make-icon.swift
iconutil -c icns build/AppIcon.iconset -o Bundle/AppIcon.icns
```

## Architecture

`Sources/OneBar/` splits into `Services/` (behavior + state, all singletons), `Views/` (SwiftUI), and `Support/` (models, helpers).

**Everything is a `@MainActor` singleton.** Services are `static let shared` and most are `@Observable`, so views read them directly (`AppState.shared`, `SystemStatsService.shared`) rather than via `@EnvironmentObject`. The package builds with `-parse-as-library`.

**Two scenes, plus manually-managed windows.** `OneBarApp` declares a `MenuBarExtra` (`.window` style → `MenuView`) and a `Window(id: "preferences")` with `.defaultLaunchBehavior(.suppressed)`. Everything else — the clipboard panel, the keyboard-cleaning overlay, the HUD pill, the prevent-sleep status item — is an `NSPanel`/`NSWindow`/`NSStatusItem` created imperatively by its owning service. `AppDelegate` wires startup (start polling, start stats, register hotkey) and teardown.

**Settings live in `AppState`,** an `@Observable` singleton where every property has a `didSet` that writes to `UserDefaults` and defaults come from `defaults.register`. Adding a preference means: property + `didSet` + entry in the `register(defaults:)` dictionary + read in `init`. Changing a setting does not itself re-configure services — the Preferences panes call the side effect explicitly (e.g. `SystemStatsService.shared.restart()` after `statsInterval`, `startPolling()`/`stopPolling()` after the clipboard toggle). `keyboardCleaningActive`/`preventSleepActive`/`mouseMoveActive`/`autoClickActive`/`autoClickEditing`/`turboClickActive` are intentionally *not* persisted.

**Clipboard pipeline:** `ClipboardManager` polls `NSPasteboard.general.changeCount` every 0.5s, skips concealed/transient/auto-generated pasteboard markers and ignored source apps, dedupes identical text to the top, then enforces `maxImages` and `historyCap` (pinned items are exempt from both). Images are written as PNG files by `ClipboardStore` into `~/Library/Application Support/OneBar/images/`; `history.json` holds the metadata. OCR + QR run afterwards via `ImageAnalysisService` (Vision, off the main thread) and are patched back onto the item by id, so a `ClipboardItem` is mutable after insertion.

**Boot-scoped history:** `ClipboardStore` stamps `kern.boottime` (`BootTime.timestamp`) into `history.json`; on load, a boot-time mismatch beyond 5s drops all unpinned items and their image files. Pinned items always survive. This is the reason history "clears on restart".

**Clipboard panel keyboard model:** `ClipboardPanelController` owns a borderless non-activating `KeyablePanel` and installs three `NSEvent` monitors while visible — a local `keyDown` monitor (`handle(_:)` returns true to swallow the event), plus global and local mouse-down monitors for click-outside dismissal. `handle(_:)` branches on `isEditingSearch` (first responder is an `NSTextView`): bare-key bindings only apply when *not* typing. Esc unwinds one layer at a time: preview → action popup → search focus → hide. Selection/search/filter state lives in `ClipboardPanelModel`; `PanelAction.actions(for:)` derives the action list from the item's kind and whether OCR/QR/URL data is present.

**Shortcuts:** `ShortcutStore` maps `ShortcutAction` → `KeyBinding` (raw `keyCode` + modifier mask), persisted as JSON. Only `openPanel` is user-rebindable *and* global — every other binding is matched inside the panel's local monitor. Global hotkeys go through `HotkeyManager`, which uses Carbon `RegisterEventHotKey` (permission-free, unlike an `NSEvent` monitor, which would drag in Input Monitoring). It holds several at once, keyed by `GlobalHotkey` — whose raw values are Carbon hotkey ids, so never renumber a shipped case — and the C handler reads the fired id back out of the event with `GetEventParameter` because a C function pointer can't capture anything. Rebinding `openPanel` re-registers immediately.

**Permission-gated features:** keyboard cleaning (a `.cghidEventTap` `CGEvent.tapCreate` swallowing key events plus the `NX_SYSDEFINED` hardware-button subtypes — volume/brightness/media/eject/power — behind a `.screenSaver`-level overlay per screen; Touch ID is unaffected because fingerprint reads never produce a CGEvent) and pasting (`PasteService` synthesizes ⌘V via `CGEvent`) both require Accessibility and check `AXIsProcessTrusted()`; both degrade quietly rather than erroring. Scan Text/QR shells out to `/usr/sbin/screencapture -i -c` and needs Screen Recording — the `Process` must be retained in `ScreenCaptureService.runningProcess`, since a still-running deallocated `Process` crashes the app.

**Cursor movement is shared.** `Support/CursorMotion.swift` owns every synthetic pointer move: an eased 60fps path of `.mouseMoved` `CGEvent`s posted at `.cghidEventTap` (a single jump gets coalesced into no visible movement at all), with duration derived from distance ÷ speed so long and short moves look alike, and an optional `curve` that bows the path off the straight line via a quadratic bezier whose control point is randomised in size and side. Every step compares the cursor's actual position against the last one posted and returns `false` if they diverge — our own events land exactly where we put them, so any drift is a real hand on the mouse. Positions everywhere are read via `CGEvent(source: nil)?.location`, already in flipped top-left event space, which is why no multi-monitor coordinate conversion exists anywhere in the codebase except `NSScreen.eventSpaceOrigin` (used only to map nodes into a canvas window's view coordinates).

**Auto Mouse Move:** `MouseMoveService` sweeps the cursor out and back through `CursorMotion` (straight, `curve: 0`), which resets `HIDIdleTime` — the clock Teams/Slack read to decide you're away. In idle-aware mode the timer ticks faster than the configured interval and the nudge is gated on `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)`, so real input postpones it rather than racing it. The return leg only runs if the outward one completed. `mouseMoveNatural` (on by default) curves the path, tilts the sweep off horizontal, varies its length, and jitters the timing — on a fixed schedule that means a one-shot timer re-armed with a fresh interval each tick, since there the interval is the only thing left to be regular; idle mode instead re-rolls its idle threshold per fire. Destinations go through `CursorMotion.clamp` first: a point past the screen edge is clamped by the WindowServer, and the cursor would then not be where we posted it, which `glide` would read as interference. Needs Accessibility, mirrors `SleepPreventionManager` for auto-off and the second status item.

**Auto Click:** three pieces. `ClickSequence` (in `Support/ClickNode.swift`) is the `@Observable` list of `ClickNode`s persisted to `UserDefaults` as JSON; positions are stored in event space so nothing is converted at run time. `ClickCanvasController` puts one transparent borderless `CanvasWindow` per display at `.statusBar` level hosting `ClickCanvasView` — click empty space to drop a point, drag to move, select for the inspector. `AutoClickService` walks the list: travel via `CursorMotion` with the configured curve, scatter the landing point by the jitter radius, act, then wait a delay randomised by the variance fraction. A node acts in one of four ways — click, type, slide or scroll. Typing overrides each event's unicode payload (`keyboardSetUnicodeString` on a `virtualKey: 0` event) instead of mapping keycodes, so it is layout-independent; newlines are sent as a real Return keypress because a literal `\n` in the payload is ignored by most text fields. A slide holds a button down along the path and posts its mouse-up on *every* exit path, since bailing out mid-drag would leave the system holding a button with nothing to release it. A scroll posts `scrollWheelEvent2` events with an explicit `event.location` — wheel events go to whatever is under the pointer, not to whatever has focus — and accumulates emitted distance across steps because integer wheel deltas would otherwise round small per-step amounts away to nothing. A double click is one event stream with `.mouseEventClickState` escalating — two plain clicks read as two singles — and the button is held ~20ms because a zero-length press is dropped by some controls. Three independent stops, because a running clicker owns your input: the Esc kill switch (a Carbon hotkey registered *only while running*, since a permanently held bare Esc would be swallowed system-wide), resistance stop (a `CursorMotion` glide returning `false`), and the auto-off timer. The canvas is flipped to `ignoresMouseEvents` during a run or it eats the very clicks being posted underneath it. `ClickLayoutStore` keeps named setups in `click-layouts.json` beside the clipboard history — on disk rather than in `UserDefaults`, since a layout is a file worth finding and backing up.

**Turbo click:** `TurboClickService` is deliberately *not* part of the sequence — it clicks wherever the pointer already is, reading `CursorMotion.location` every tick so it follows the cursor rather than latching a position. Starting it stops `AutoClickService`, since both drive the one pointer. Rate is capped at `TurboClickService.maxRate` (100/sec); Autoclick's author found macOS locks up past 900. It shares the Esc kill switch by registering the same `.autoClickStop` hotkey while it runs. Both it and the sequence post buttons through `Support/MouseEvents.swift`, so the events are identical — turbo skips the ~20ms hold because at high rates there is no room for one.

**Pick Color:** `ColorPickerService` shows `NSColorSampler`, AppKit's own loupe — sampling happens outside our process, so unlike Scan Text/QR it needs no Screen Recording grant. The sample is converted through `usingColorSpace(.sRGB)` before its components are read, since it arrives in the sampled display's own space and `redComponent` on a non-RGB colour traps. The formatted string (`ColorFormat` in `Support/Models.swift`) just goes on the pasteboard; `ClipboardManager`'s poll picks it up as an ordinary text item, so history and search come free. A `nil` callback is Esc and stays silent, like a cancelled `screencapture -i`.

**Menubar label:** `MenuBarExtra` mangles stacked/inline views in its label, so the live CPU/MEM readout is pre-rendered to a single template `NSImage` via `ImageRenderer` in `MenuBarLabel.statsImage`.

## Conventions

- Use `.liquidGlass(in:)` (`Support/LiquidGlass.swift`) for glass surfaces rather than calling `glassEffect`/`.ultraThinMaterial` directly — it holds the macOS 26 availability fallback in one place.
- Transient user feedback goes through `HUD.show(_:symbol:)`, not alerts.
- Timers are created with `Timer(...)` + `RunLoop.main.add(timer, forMode: .common)` so they keep firing during menu tracking; callbacks hop back with `Task { @MainActor in ... }`.
- Comments in this codebase explain *why* a non-obvious workaround exists (AppKit quirks, permission behavior). Match that — don't add narration of what the code plainly does.
