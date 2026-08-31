# Changelog

All notable changes to **osx-window-manager**, grouped by date.
There is no version number; dates match git history on `main`.

Site: https://lotar.github.io/osx-window-manager/

---

## 2026-08-31

### Added

- CLI flags to register and query Launch at Login without opening Settings:
  `--enable-launch-at-login` and `--launch-at-login` (`SMAppService`).
- Packaged, signed `dist/osx-window-manager.app` is tracked in git so a clone
  can `open dist/osx-window-manager.app` without a local Swift build.

`55616fe`

---

## 2026-08-24

Tiling against apps that refuse a size (Electron: Slack, WhatsApp; others with
a large minimum window) became one-press-correct instead of “press twice / creep.”

### Changed

- `perform()` animates to the ideal tile, waits off the main thread for the
  settled frame, then re-pins if the app clamped. Direct AX resize writes are
  not trusted; animation writes are. (`629bb9f`)
- Probe asks each axis separately (height first, then width at the accepted
  height) so a min-height app no longer returns garbage on **both** axes.
  (`3e61f73`)
- Probe retry only counts as success when the axis that was asked to change
  actually moved. Write order is size → position → size. (`39144fd`)
- After settle, grow writes that were dropped (app busy) are re-issued up to
  twice. (`f1e044c`)
- Quarter-slides from a half/maximize use a 2 pt dead-zone around screen
  center, so 1 pt rounding no longer flips top vs bottom row. (`88214bd`)

### Added

- `scripts/transition_matrix.py` — 8 start states × 8 actions = 64 live
  transitions through the real `perform()` path. (`88214bd`)
- Bridge `perform:<action>` mode so tests drive the real hotkey path, not
  `debugRoundTrip`. (`629bb9f`)

### Docs

- README / site: animate-then-correct, HUD min-size warning. (`f85468e`)

---

## 2026-08-23

Open-source packaging and the public site.

### Changed

- Renamed **Glass** → **osx-window-manager**. Bundle id
  `com.lotar.osx-window-manager`, UserDefaults domain `osx-window-manager`,
  log `/tmp/owm.log`, Carbon signature `OWMG`. (`8291b92`)
- Landing page moved to `docs/` for GitHub Pages (`main` + `/docs`).
  (`679164e`, `bccd9c6`)
- README: install, shortcuts, troubleshooting; unmaintained / AI-limits-test
  disclaimer. (`4e757ff`, `913c92e`, `92dbeaf`, `81c176c`)

### Added

- MIT `LICENSE`. (`8291b92`)

---

## 2026-08-22

Settings UI, real 2×2 quarters, HUD, and movement-matrix tests.

### Added

- Settings window rebuilt: sectioned cards, keycap shortcut pills, live
  Accessibility chip, gap stepper, Launch at Login switch. (`b0bef4e`)
- HUD toast on every move; names the app and its minimum size when a tile
  cannot shrink. (`2afed2b`)
- Quarter tiles are true screen quadrants (½ width × ½ height) so four windows
  cover the visible frame. (`206bd7d`)
- `scripts/matrix_test.py` (pure geometry) and `scripts/live_matrix.py` (live
  window via the trusted-app bridge). (`2afed2b`)
- Rapid keypress isolation: a new press cancels in-flight animation + settle.
  (`2afed2b`)
- Hotkey dispatch logs delivered modifiers to `/tmp/owm.log` (then
  `/tmp/glass.log`) so remappers are visible. (`974a485`)

### Fixed

- Clamped full-axis tiles (e.g. Slack refusing `topHalf` height) no longer park
  in a corner. Width is retried at the accepted height; halves center on the
  unconstrained axis. (`1134e1f`)

---

## 2026-08-21

First week: Glass ships, then coordinate, clamp, and slide bugs get fixed
against live windows.

### Added

- Initial menu-bar tiler: global Carbon hotkeys, halves / thirds / two-thirds /
  maximize / center / restore / displays, Settings, Launch at Login, Accessibility
  prompt. (`444c642`)
- Darwin-notification round-trip bridge so an untrusted shell can drive geometry
  through the trusted running app (`notifyutil` + `/tmp/owm-roundtrip.*`).
  (`e231d20`)
- `--roundtrip` CLI for live AX read → tile → write → re-read. (`c26ee6d`)

### Fixed

- Top/bottom tiles inverted: AX position is Quartz (Y down); writes now flip
  Cocoa Y about main-display height. (`debe998`)
- Cocoa ↔ Quartz conversion uses one main-display pivot for reads and writes
  (multi-display arrangements no longer drift). (`c26ee6d`)
- Apps with a minimum window size larger than a quarter overflowed the tile
  (often off-screen). After settle, `rePinClamped()` anchors to the intended
  corner. (`8e42bc8`)
- Quarter animation overshot then snapped back. Probe accepted size **before**
  animating; animation target is the achievable on-screen rect. (`7d5b8bb`)
- Shift+arrows became **relative** slides on the 2×2 grid (left/right = column,
  up/down = row) instead of jumping to a named corner. (`7d5b8bb`)
- Halves / thirds / two-thirds cycle when you re-press the occupied tile.
  (`211cf25`)
- Edge slides are no-ops (no wrapping off the screen). (`dedaebd`)
- `settleAndRepin()` waits until the frame stops changing before pinning
  (late min-size clamps no longer leave a window under the Dock). (`dedaebd`)
