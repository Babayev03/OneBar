<p align="center">
  <img src="docs/icon.png" width="128" alt="OneBar icon">
</p>

<h1 align="center">OneBar</h1>

<p align="center">
  A free, open-source macOS menubar utility — clipboard history with OCR & QR superpowers,
  system monitoring, keyboard cleaning, prevent-sleep, auto mouse move, and a
  visual auto clicker with turbo mode. One icon, everything at hand.
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

### 📊 System monitoring
- CPU / memory / disk rings in the popover with configurable warning & critical thresholds
- Hover a ring to morph it into the exact percentage
- Optional **live CPU + MEM readout right in the menubar**

### 🧽 Keyboard cleaning
- Blocks every key system-wide (yes, including `⌘Q`) behind a dimmed overlay while you wipe your keyboard — mouse-only exit plus an auto-exit countdown
- Hardware buttons are blocked too: volume, brightness, media/playback, keyboard backlight, eject and the power button
- **Touch ID keeps working** — a fingerprint read goes straight to the Secure Enclave and never passes through the key blocker

### ☕ Prevent sleep
- Keeps both the Mac **and the screen** awake — no screen turning off mid-task; an "Allow the display to sleep" option opts back out if you want the screen dark while the Mac keeps working
- "Temporary & safe": auto-released on quit, optional auto-off timer, and a separate menubar cup icon while active so you can't forget it

### 🖱️ Auto mouse move
- Keeps **Teams, Slack and friends on Available** instead of flipping you to Away while you're reading, on a call, or away from the desk
- Glides the pointer out and back along a **smooth eased path** — no jarring teleport — which is all it takes to reset the idle clock those apps watch
- **Never fights you for the cursor**: "Only while you're away" waits for real input to stop, and grabbing the mouse mid-sweep aborts the move instantly
- Nothing is ever **clicked or typed** — it only moves
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

## Install

Requires **macOS 26+** and Xcode command line tools.

```sh
git clone https://github.com/Babayev03/OneBar.git
cd OneBar
./build-app.sh
```

That builds a release binary, assembles `OneBar.app`, ad-hoc signs it, installs it to `/Applications`, and launches it.

### Permissions

macOS will ask for these on first use of the corresponding feature:

- **Accessibility** — required for keyboard cleaning, auto mouse move, auto click, and pasting into other apps (System Settings → Privacy & Security → Accessibility)
- **Screen Recording** — required for Scan Text / Scan QR

Everything runs **100% on-device**. OneBar makes no network requests, ever.

## Preferences

- Launch on start
- Live menubar stats, update frequency, ring thresholds
- Image limit & optional history cap
- Ignored apps
- Fully remappable shortcuts, including global ones for the clipboard panel (`⌘H`), the Auto Click canvas (`⌥⌘C`) and turbo click (`⌥⌘T`)
- Keyboard-cleaning duration, prevent-sleep auto-off and display-sleep behavior, accent color
- Auto mouse move interval, distance, speed, idle-awareness and auto-off
- Auto click repeat count, travel speed, typing speed, click scatter, timing variation, path curve and auto-off
- Turbo click rate and button

## License

[MIT](LICENSE) — do whatever you like, no warranty. Long live open source. 🖤
