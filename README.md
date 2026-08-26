<p align="center">
  <img src="docs/icon.png" width="128" alt="OneBar icon">
</p>

<h1 align="center">OneBar</h1>

<p align="center">
  A free, open-source macOS menubar utility — clipboard history with OCR & QR superpowers,
  a drag-and-drop shelf, system monitoring, brightness for every display, sound with per-app
  volume, keyboard cleaning, prevent-sleep, auto mouse move, and a visual auto clicker with
  turbo mode. One icon, everything at hand.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20Liquid%20Glass-purple" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

---

## Features

### 📋 Clipboard history
- **Unlimited text history** — automatically cleared when the Mac restarts; **pinned items survive everything**
- Keeps the last **20 images** (configurable), oldest evicted first
- **OCR on every image** (Apple Vision, fully on-device): screenshots become *searchable by the text inside them*
- **QR detection**: copy a QR code image and OneBar extracts the payload — copy it or open the link directly
- Filter chips (All / Text / Images / Links), pinned/recent sections, Spacebar full preview
- Ignored-apps list (copies from those apps are never recorded), and password-manager content is skipped automatically (`org.nspasteboard.ConcealedType`)
- Paste straight into the frontmost app — original or plain text

Keyboard-driven panel (every key remappable in Preferences):

| Key | Action |
| --- | --- |
| `⌘H` | Open clipboard history (global) |
| `S` | Focus search |
| `↑` `↓` | Navigate items / actions |
| `Enter` | Open the actions popup / run highlighted action |
| `O` / `P` | Paste original / paste plain text |
| `^V` | Paste plain text directly |
| `⌘Enter` | Open URL |
| `Space` | Full preview |
| `Tab` | Cycle filters |
| `Delete` | Delete item |

### 🗄️ Shelf
Drag a file from one window to another without both being visible at once. **Shake the cursor mid-drag** and a shelf appears under it — drop things in, go anywhere, then drag them all back out together. On a MacBook with a notch you can **drop onto the notch** instead.

- **Nothing is ever copied.** A shelf holds *references*, so it costs no disk space and deleting a shelf never deletes your files. Dropped text and images have no file to reference, so OneBar writes one — that is the only thing it writes, and it is what lets you drag a snippet of text straight into Finder as a `.txt`
- **Native drag-out semantics**: same volume moves, different volume copies, `⌥` forces a copy — because the shelf offers macOS both operations and lets the destination decide. There is a preference to always copy
- **Several shelves at once** (five by default, adjustable — each one is a live window, so a lot of them costs frame rate), each with its own name and colour. **Pin** one and it comes back at launch; close one by accident and it waits on a recents list
- **Dock or retract** a shelf to a screen edge, where it collapses to a tab that peeks on hover. Snap-to-edge on move, `⌘` to suppress it, and an option to keep a shelf in the Space it was opened in
- **Grid or list**, multi-selection, Quick Look, and per-item actions: Open, Open With, Show in Finder, **rename in place** (Finder-style — the base name is selected, the extension is not), Copy, Move to New Shelf, **Share** via the real AirDrop / Mail / Messages sheet, and Move to Trash
- **Transform actions**: **Compress** to a zip, **convert or resize images** (JPEG / PNG / HEIC / TIFF / AVIF, plus **WebP** where `cwebp` is installed — presets or your own size and quality, and resizing keeps the format it already was and never upscales), **remove metadata** (strips EXIF, GPS and camera tags without re-encoding the image), and **merge PDFs and images into one PDF**. Results go to a folder of your choosing and can land on the shelf, in Finder, or both; **your originals are never touched**
- **⌘K command bar** — type what you want done instead of hunting for it: "zip" finds Compress, "delete" finds Move to Trash, "webp" converts straight to WebP. Only what is currently possible is listed
- **Get Info** for the selected item — kind, size, pixel dimensions, location and dates — and **Copy Path**
- **Ignored apps** — add an app and shaking inside it never summons a shelf
- Needs **no permission at all**: watching for a shake uses mouse monitors, and only *keyboard* monitors require Accessibility

| Key | Action |
| --- | --- |
| `Space` | Quick Look |
| `Return` | Rename in place |
| `⌘I` | Get Info |
| `⌘K` | Run an action — search by name or synonym |
| `⌘O` | Open |
| `⌘R` | Show in Finder |
| `⌘C` / `⌘V` | Copy selection / add from clipboard |
| `⌘A` | Select all |
| `Delete` | Remove from shelf |
| `⌘Delete` | Clear shelf |
| `⌘D` / `⌥⌘←` / `⌥⌘→` | Dock to nearest / left / right edge |
| `⇧⌘I` | Customize (name, colour, pin) |
| `⌘N` | New shelf from clipboard |
| `⌘W` / `⇧⌘W` | Close shelf / close all |

### 📊 System monitoring
- CPU / memory / disk rings in the popover with configurable warning & critical thresholds
- Hover a ring to morph it into the exact percentage
- Optional **live CPU + MEM readout right in the menubar**

### 🧽 Keyboard cleaning
- Blocks every key system-wide (yes, including `⌘Q`) behind a dimmed overlay while you wipe your keyboard — mouse-only exit plus an auto-exit countdown
- Hardware buttons are blocked too: volume, brightness, media/playback, keyboard backlight, eject and the power button
- **Touch ID keeps working** — a fingerprint read goes straight to the Secure Enclave and never passes through the key blocker

### ☕ Prevent sleep
- **Sessions, not a switch**: keep the Mac awake indefinitely, for a set number of minutes or hours, for a custom length, until a time of day, **while an app is running**, or **while a file is downloading** — the session ends itself when its reason does
- **Closed-lid mode**: keeps working with the lid shut *on battery*, which macOS otherwise refuses without a power adapter and an external display
- Keeps the screen awake too, unless you opt out with "Let the display sleep"
- Safe by construction: a **low-battery cutoff**, a live countdown on a separate menubar cup icon, and everything — including the lid — handed back whenever OneBar quits, however it quits, and on the next launch after a crash

### 🔆 Display brightness
- **Brightness sliders for every screen**, including external monitors macOS itself gives you no control over — the F1/F2 keys only ever move the built-in panel
- Opens the way Control Center does: a **Display** row in the menu with a slider for the screen you're on, and a click takes you to a screen with **one card per monitor**
- External monitors are driven over **DDC/CI**, the protocol the monitor's own scaler speaks, so it's the real backlight moving — the same thing the buttons on the monitor do
- The built-in display goes through the same path macOS uses itself, so System Settings agrees with the slider
- A monitor that won't answer DDC (some need DDC/CI enabling in their own menu) falls back to **software dimming**, which is labelled as such rather than pretending — and is put back the moment OneBar quits
- **No new permissions**

### 🔊 Sound
- **Volume, mute and output switching** for every device, in the menu and on a screen of its own — the same things Control Center does, one click closer
- **Output groups — play to several devices at once** (laptop speakers *and* AirPods, say). macOS can do this, but only as a "Multi-Output Device" buried in Audio MIDI Setup; OneBar makes it a **named group you pick like any other output**
- **The volume keys keep working under a group.** A multi-output device has no volume control of its own, which is why F11/F12 go dead the moment you select one — the standing complaint about them. OneBar takes the keys over while a group is playing and moves every device in it together
- **Per-app volume** — turn a browser down without touching your music, or mute one app outright. **No audio driver and no installer**: it uses the process taps macOS has had since 14.2, so nothing is added to your system
- **Alert volume and UI sound effects**, the two settings that live outside the audio devices entirely — how loud beeps and notifications are, and whether interface sounds play at all. The same values System Settings shows, so the two always agree
- **Input device picker**, with an optional live level meter — off by default, since a meter means opening the microphone and lighting the orange dot in the menu bar
- Devices that genuinely have no volume control (some USB interfaces, the Continuity iPhone mic) are shown with the slider disabled and a note, rather than a slider that silently does nothing

### 🖱️ Auto mouse move
- Keeps **Teams, Slack and friends on Available** instead of flipping you to Away while you're reading, on a call, or away from the desk
- Glides the pointer out and back along a **smooth eased path** — no jarring teleport — which is all it takes to reset the idle clock those apps watch
- **Never fights you for the cursor**: "Only while you're away" waits for real input to stop, and grabbing the mouse mid-sweep aborts the move instantly
- Nothing is ever **clicked or typed** — it only moves
- **Natural movement**: curves the path and varies its length, angle and timing, so it isn't a machine redrawing one line forever
- Configurable interval, distance (up to 500 px) and speed, plus an auto-off timer and its own menubar icon while active

### 🎯 Auto click
- Drop **click points anywhere on screen** on a transparent canvas, drag them where they need to go, and they fire **in order** along a visible chain
- Four point types: **click** (left/right/middle, single or double), **text** (types a stored string at human speed, any keyboard layout), **slide** (press-drag-release, so it really moves files and sliders) and **scroll**
- Per point: how long to wait afterwards, plus size and opacity so the markers stay out of your way
- Moves between points along a **curved, eased path** with configurable click scatter and timing variation, so a long run isn't a metronome hitting one pixel
- **Three ways out**, because a running clicker owns your input: **Esc** stops it instantly, grabbing the mouse stops it, and an auto-off timer stops it
- Runs a set number of passes or loops until you stop it; your points are saved between launches
- Open the canvas from the menubar or a **global shortcut** (`⌥⌘C` by default, rebindable)
- Save setups to the **layout library** and switch between them in a click

### ⚡ Turbo click
- Clicks wherever the pointer already is — no points involved. Toggle it from anywhere with a **global shortcut** (`⌥⌘T` by default)
- Configurable rate and button, capped at 100 clicks/second — well below the rate that locks macOS up
- Same **Esc** kill switch, and its own menubar icon while running

### 🔍 Scan Text / Scan QR
- Select any region of your screen and instantly get its **text (OCR)** or **QR payload** on the clipboard

### 🎨 Pick color
- A loupe over any pixel on screen — grab a color out of a screenshot, a website, another app's UI
- Copies as **hex**, **HEX**, **CSS `rgb()`** or a **SwiftUI `Color`**, your pick
- Lands in clipboard history like anything else you copy, so it stays searchable
- Global shortcut (`⌥⌘P` by default), and **no Screen Recording permission** — the sampling happens outside OneBar

## Install

Requires **macOS 26+** and Xcode command line tools.

```sh
git clone https://github.com/Babayev03/OneBar.git
cd OneBar
./build-app.sh
```

That builds a release binary, assembles `OneBar.app`, ad-hoc signs it, installs it to `/Applications` (or `~/Applications` if that isn't writable), and launches it.

### Permissions

macOS will ask for these on first use of the corresponding feature:

- **Accessibility** — required for keyboard cleaning, auto mouse move, auto click, and pasting into other apps (System Settings → Privacy & Security → Accessibility)
- **Screen Recording** — required for Scan Text / Scan QR
- **System Audio Recording** — required only for **per-app volume**. macOS calls reading an app's audio "recording"; it is played straight back out at the level you picked, and nothing is stored or sent anywhere
- **Microphone** — only if you switch on the input level meter, and only while the Sound screen is open

Display brightness, Pick color and the Shelf need **none of them** — DDC/CI, the built-in backlight, the system color sampler and mouse-only event monitors are all permission-free.

Everything runs **100% on-device**. OneBar makes no network requests, ever.

## Preferences

- Launch on start
- Live menubar stats, update frequency, ring thresholds
- Image limit & optional history cap
- Ignored apps
- Shelf: shake on/off and sensitivity, drop-to-notch and its highlight, where a shelf opens, grid or list, keep dropped text as plain text, always copy when dragging out, when to close after a drag out, retract after the first drop, snap on move, what double-clicking a shelf edge does, per-shelf colours, and its own ignored-apps list
- Fully remappable shortcuts, including global ones for the clipboard panel (`⌘H`), the Auto Click canvas (`⌥⌘C`), turbo click (`⌥⌘T`) and pick color (`⌥⌘P`)
- What `⌘Q` does — ask first, quit, or do nothing (the Quit button in the menu always quits)
- Keyboard-cleaning duration, prevent-sleep auto-off and display-sleep behavior, accent color
- Auto mouse move interval, distance, speed, idle-awareness and auto-off
- Auto click repeat count, travel speed, typing speed, click scatter, timing variation, path curve and auto-off
- Turbo click rate and button
- Display brightness controls on/off, and whether to fall back to software dimming
- Sound controls on/off, and the microphone level meter
- The format picked colors are copied in

## License

[MIT](LICENSE) — do whatever you like, no warranty. Long live open source. 🖤
