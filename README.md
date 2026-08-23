# osx-window-manager

Menu-bar macOS window manager: global shortcuts tile the frontmost window.

## Requirements

- macOS 14+
- Apple Silicon
- Accessibility permission (System Settings → Privacy & Security → Accessibility)

## Build & Install

```bash
swift build
./.build/debug/osx-window-manager
```

Release binary:

```bash
swift build -c release
```

Packaged app (menu-bar app, Launch at Login support):

```bash
./scripts/package.sh
open dist/osx-window-manager.app
```

## Default shortcuts

| Keys | Action |
|---|---|
| ⌘⌥+← / → / ↑ / ↓ | Left / right / top / bottom half |
| ⌘⌥+1 / 2 / 3 | Left / center / right third |
| ⌘⌥+E / R | Left / right two-thirds |
| ⌘⌥+Return | Maximize |
| ⌘⌥+F | Almost maximize |
| ⌘⌥+C | Center |
| ⌘⌥+Z | Restore previous frame |
| ⌘⌥+] / [ | Next / previous display |
| ⌘⌥⇧+← / → / ↑ / ↓ | Slide quarter left / right / down / up |

Quarter tiles are half width × half height, so four windows tile the screen.
Slides are relative to the window's current quadrant and clamp at screen edges.

## Rebinding & settings

Open Settings from the menu-bar icon. Click a key cap, press the new combo,
Esc cancels. Also in Settings: tiling gap (0–40 px), Launch at Login,
Reset to Defaults.

## Configuration storage

UserDefaults domain `osx-window-manager`.

## Troubleshooting

- No windows move: grant Accessibility, then relaunch.
- Diagnostics: `/tmp/owm.log`.
- Some apps enforce minimum window sizes larger than a tile; the HUD warns
  with the app's minimum size and the window is pinned to the nearest corner.

## License

MIT — see [LICENSE](LICENSE).
