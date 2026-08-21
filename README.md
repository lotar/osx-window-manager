# Glass — menu-bar macOS window tiler

Menu-bar-only (no Dock icon) window manager: global shortcuts tile the
frontmost window, a glass settings window rebinds them, and a gap slider
plus Launch at Login live in the same UI.

macOS 14+, Apple silicon.

## Build & run

```bash
swift build
./.build/debug/Glass
```

Release:

```bash
swift build -c release
./.build/release/Glass
```

The debug/release binaries are SwiftPM executables (prefs domain `Glass`).
For a real `.app` (Launch at Login, `LSUIElement` in Info.plist):

```bash
./scripts/package.sh
# prints: .../dist/Glass.app
open dist/Glass.app
```

## Accessibility

Glass moves windows with the `AXUIElement` API (same as Rectangle / Magnet).
On first launch, grant **Accessibility** in System Settings → Privacy &
Security → Accessibility, then relaunch.

## Default shortcuts

All bindings use virtual keycodes + `NSEvent` modifier raw values, registered
with Carbon `RegisterEventHotKey` (not a CGEvent tap). Rebind anything in
Settings.

| Action | Default |
|---|---|
| Left half | ⌘⌥← |
| Right half | ⌘⌥→ |
| Top half | ⌘⌥↑ |
| Bottom half | ⌘⌥↓ |
| Top-left quarter | ⌘⌥⇧← |
| Top-right quarter | ⌘⌥⇧→ |
| Bottom-left quarter | ⌘⌥⇧↓ |
| Bottom-right quarter | ⌘⌥⇧↑ |
| Left third | ⌘⌥1 |
| Center third | ⌘⌥2 |
| Right third | ⌘⌥3 |
| Left two-thirds | ⌘⌥E |
| Right two-thirds | ⌘⌥T |
| Maximize | ⌘⌥⏎ |
| Almost maximize | ⌘⌥F |
| Center | ⌘⌥C |
| Restore | ⌘⌥Z |
| Previous display | ⌘⌥[ |
| Next display | ⌘⌥] |

Tiles use `NSScreen.visibleFrame` (menu bar and Dock stay uncovered). Gap `0`
by default; Restore returns the window to the pre-tile bounds.

## Settings

Menu-bar icon → **Settings…**

- **Rebind** — click a field, press the new combo. Esc cancels. Combos with
  no modifier are rejected so normal typing is never hijacked.
- **Gap** — inner inset between tiles (`gap.v1`, 0…40 pt).
- **Launch at Login** — `SMAppService` (works from the packaged `.app`).
- **Reset to Defaults** — writes the table above back to `shortcuts.v1`.

Shortcuts persist in UserDefaults domain `Glass`, key `shortcuts.v1`
(JSONEncoder of `[WindowAction: Shortcut]`). Optional gap: `gap.v1`.

## How it works

- **Global hotkeys** — Carbon `RegisterEventHotKey`.
- **Window control** — `AXUIElement` on the frontmost app's focused window.
- **Menu-bar app** — `NSApplication.setActivationPolicy(.accessory)` and
  `LSUIElement` in the packaged Info.plist (`com.lotar.glass`).
- **Settings UI** — `NSVisualEffectView` (`underWindowBackground`) +
  translucent rounded cards.

## Test

```bash
python3 e2e_test.py
```

Asserts debug+release build, `--dump-layout` math for all 19 actions, launch,
and the AX trust gate. Live window moves and menu clicks SKIP unless this
binary and Automation are granted in System Settings.
