# TODO: Screen color picker

Not implemented yet — this is the plan for the feature this branch is named after.

Pick any pixel on screen and get its colour on the clipboard. Sits beside Scan
Text / Scan QR in the menu: the same "grab something off the screen, leave it on
the clipboard" shape.

## Why `NSColorSampler`

AppKit ships the loupe: `NSColorSampler().show { color in ... }` gives the same
magnifier the system colour panel uses, and it does **not** need Screen
Recording — the sampling happens outside our process. Rolling our own loupe with
`CGDisplayCreateImage` would need that permission and a follow-cursor panel, for
a worse result.

`show(closeHandler:)` calls back with `NSColor?` — `nil` when the user hits Esc,
which must stay silent (no HUD), the way a cancelled `screencapture -i` does in
`ScreenCaptureService`.

## Sketch

- `Services/ColorPickerService.swift`, a `@MainActor enum` mirroring
  `ScreenCaptureService`: one `pick()` entry point, guarded so a second call
  while the loupe is up is a no-op.
- Convert through `usingColorSpace(.sRGB)` before reading components — the
  sampled colour can come back in the display's own space, and unconverted
  `redComponent` on that traps.
- Write the string with `NSPasteboard.general.setString`, then
  `HUD.show("#1E88E5 copied", symbol: "eyedropper")`. Nothing else to do:
  `ClipboardManager` polls `changeCount` every 0.5s and picks it up as a normal
  text item, so it lands in history and is searchable for free.

## Format

`AppState.colorPickerFormat` — an enum stored by raw value (`hex`, `hexUpper`,
`rgb`, `swiftUI`), default `hex`. Property + `didSet` + `register(defaults:)`
entry + read in `init`, like every other setting. Surface it in `GeneralPane`
next to the Scan controls.

- `hex` → `#1e88e5`
- `rgb` → `rgb(30, 136, 229)`
- `swiftUI` → `Color(red: 0.118, green: 0.533, blue: 0.898)`

## Menu + hotkey

- A third `scanButton` in `MenuView.scanRow` — the row is currently two buttons
  wide, so either it becomes a three-up row or Pick Colour gets its own row.
  Decide once it's on screen.
- Optional global hotkey: add `case pickColor = 5` to `GlobalHotkey` (next free
  Carbon id — never renumber the shipped cases) plus a `ShortcutAction` entry so
  it shows in `ShortcutsPane`.

## Done when

- Loupe opens from the menu, Esc cancels silently.
- Picked colour lands on the clipboard in the configured format, HUD confirms,
  and the item appears in clipboard history.
- Works on a second display and on a Retina/non-Retina mix.
