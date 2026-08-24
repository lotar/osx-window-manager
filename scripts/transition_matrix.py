#!/usr/bin/env python3
"""Full 1/4 <-> 1/2 transition matrix for osx-window-manager.

8 start states (4 quarters + 4 halves) x 8 pressed actions
(4 half keys + 4 quarter-slide keys) = 64 transitions.

Each transition: position the TextEdit window to the start state via the
trusted-app bridge, press the test action, read the AX frame back, and
compare against the expected tile per the engine's semantics:
  - half keys: absolute halves
  - shift keys: relative quarter slide, clamped at edges
  - min-size clamps: size may exceed the tile but must be anchored to the
    correct corner/edges and stay fully inside the visible frame

Per-step exact-scale visualization is rendered (expected outline + actual
window fill) and a montage is written to /tmp/tmatrix/.
"""
import itertools
import os
import re
import subprocess
import sys
import time

from PIL import Image, ImageDraw

VX, VY, VW, VH = 0.0, 90.0, 1728.0, 994.0   # visible frame (cocoa)
SCREEN_H = 1117.0
ACTION_FILE = "/tmp/owm-roundtrip.action"
PID_FILE = "/tmp/owm-roundtrip.pid"
SEQ_FILE = "/tmp/owm-roundtrip.seq"
LOG = "/tmp/owm-roundtrip.log"
OUT = "/tmp/tmatrix"
SCALE = 0.28
TOL = 8.0

SEQ = itertools.count(1)
TEST_PID = None

CORNER_DIRS = {"topLeft": (-1, 0), "topRight": (1, 0),
               "bottomLeft": (0, -1), "bottomRight": (0, 1)}
HALVES = {"leftHalf", "rightHalf", "topHalf", "bottomHalf"}
PRESSED = ["leftHalf", "rightHalf", "topHalf", "bottomHalf",
           "topLeft", "topRight", "bottomLeft", "bottomRight"]
KEY_OF = {"leftHalf": "cmd-opt-LEFT", "rightHalf": "cmd-opt-RIGHT",
          "topHalf": "cmd-opt-UP", "bottomHalf": "cmd-opt-DOWN",
          "topLeft": "cmd-opt-shift-LEFT", "topRight": "cmd-opt-shift-RIGHT",
          "bottomLeft": "cmd-opt-shift-DOWN", "bottomRight": "cmd-opt-shift-UP"}


def tile(name):
    qw, qh = VW / 2, VH / 2
    tw = VW / 3
    return {
        "leftHalf": (VX, VY, VW / 2, VH),
        "rightHalf": (VX + VW / 2, VY, VW / 2, VH),
        "topHalf": (VX, VY + VH / 2, VW, VH / 2),
        "bottomHalf": (VX, VY, VW, VH / 2),
        "bottomLeft": (VX, VY, qw, qh),
        "bottomRight": (VX + VW / 2, VY, qw, qh),
        "topLeft": (VX, VY + VH / 2, qw, qh),
        "topRight": (VX + VW / 2, VY + VH / 2, qw, qh),
        "maximize": (VX, VY, VW, VH),
    }[name]


def resolve(action, current):
    """Mirror WindowEngine.resolvedAction for corners; others absolute."""
    if action not in CORNER_DIRS:
        return action
    dc, dr = CORNER_DIRS[action]
    mx, my = current[0] + current[2] / 2, current[1] + current[3] / 2
    col = 0 if abs(mx - (VX + VW / 2)) <= 2 else (0 if mx < VX + VW / 2 else 1)
    row = 1 if abs(my - (VY + VH / 2)) <= 2 else (0 if my < VY + VH / 2 else 1)
    nc = min(max(col + dc, 0), 1)
    nr = min(max(row + dr, 0), 1)
    return {(0, 1): "topLeft", (1, 1): "topRight",
            (0, 0): "bottomLeft", (1, 0): "bottomRight"}[(nc, nr)]


def pinned(target, size, action):
    """Mirror WindowEngine.pinnedRect."""
    ox, oy = target[0], target[1]
    tx, ty, tw, th = target
    if action in ("rightHalf", "topRight", "bottomRight", "rightThird", "rightTwoThirds"):
        ox = tx + tw - size[0]
    elif action in ("centerThird", "maximize", "almostMaximize", "center",
                    "topHalf", "bottomHalf"):
        ox = tx + tw / 2 - size[0] / 2
    if action in ("topHalf", "topLeft", "topRight", "leftThird", "centerThird",
                  "rightThird", "leftTwoThirds", "rightTwoThirds"):
        oy = ty + th - size[1]
    elif action in ("bottomHalf", "bottomLeft", "bottomRight"):
        oy = ty
    elif action in ("leftHalf", "rightHalf"):
        oy = ty + th / 2 - size[1] / 2
    return (ox, oy, size[0], size[1])


def trigger(action):
    seq = next(SEQ)
    open(ACTION_FILE, "w").write("perform:" + action)
    open(SEQ_FILE, "w").write(str(seq))
    open(PID_FILE, "w").write(str(TEST_PID))
    try:
        os.remove(LOG)
    except FileNotFoundError:
        pass
    for _ in range(2):  # re-post once if the Darwin notification is lost
        subprocess.run(["notifyutil", "-p", "com.lotar.osx-window-manager.roundtrip"])
        for _ in range(25):
            time.sleep(0.2)
            if os.path.exists(LOG):
                if f"seq={seq} action=perform:{action}" in open(LOG).read():
                    return parse_report()
    return None


def parse_report():
    if not os.path.exists(LOG):
        return None
    text = open(LOG).read()
    m_res = re.search(r"resolved=(\S+)", text)
    m_after = re.search(r"after\s+quartz=\(([-\d.]+), ([-\d.]+)\) size=\(([\d.]+), ([\d.]+)\)", text)
    if not (m_res and m_after):
        return None
    qx, qy, w, h = map(float, m_after.groups())
    return {"resolved": m_res.group(1), "frame": (qx, SCREEN_H - qy - h, w, h)}


def close(a, b, tol=TOL):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def to_px(rect):
    x, y, w, h = rect
    return [20 + x * SCALE, 20 + (VY + VH - (y + h)) * SCALE, w * SCALE, h * SCALE]


def render(idx, label, expected, actual, ok, note):
    W = int(VW * SCALE) + 40
    H = int((VY + VH) * SCALE) + 40 + 22
    img = Image.new("RGB", (W, H), (22, 24, 30))
    d = ImageDraw.Draw(img)
    vx0, vy0, _, _ = to_px((VX, VY, 0, 0))
    d.rectangle([vx0, vy0, vx0 + VW * SCALE, vy0 + VH * SCALE],
                fill=(44, 48, 58), outline=(110, 110, 120))
    ex, ey, ew, eh = to_px(expected)
    d.rectangle([ex, ey, ex + ew, ey + eh], outline=(80, 160, 255), width=2)
    ax, ay, aw, ah = to_px(actual)
    d.rectangle([ax, ay, ax + aw, ay + ah],
                fill=(60, 200, 110) if ok else (220, 80, 90), outline=None)
    d.text((20, H - 18), f"{'OK ' if ok else 'FAIL'} {label} {note}",
           fill=(200, 200, 160) if ok else (255, 120, 120))
    path = f"{OUT}/{idx:03d}_{ok and 'ok' or 'fail'}.png"
    img.save(path)
    return path


def main():
    global TEST_PID
    os.makedirs(OUT, exist_ok=True)
    pid_out = subprocess.run(["pgrep", "-x", "TextEdit"], capture_output=True, text=True).stdout.strip()
    if not pid_out:
        print("TextEdit not running"); return 1
    TEST_PID = int(pid_out.splitlines()[0])
    print(f"targeting TextEdit pid={TEST_PID}")

    # start-state positioning sequences (presses from maximize)
    starts = {
        "Q-topLeft": ["bottomRight", "topRight"],      # max -> up (top-left) ... then verify
        "Q-topRight": ["bottomRight", "topRight"],
        "Q-bottomLeft": ["topLeft"],
        "Q-bottomRight": ["topRight"],
        "H-left": ["leftHalf"],
        "H-right": ["rightHalf"],
        "H-top": ["topHalf"],
        "H-bottom": ["bottomHalf"],
    }
    # derive exact start rects by simulating from maximize
    maxr = (VX, VY, VW, VH)
    start_rects = {}
    # every sequence normalizes with maximize first (relative slides assume it)
    pos_actions = {
        "Q-topLeft": ["maximize", "bottomRight", "topLeft"],
        "Q-topRight": ["maximize", "bottomRight", "topRight"],
        "Q-bottomLeft": ["maximize", "topLeft"],
        "Q-bottomRight": ["maximize", "topRight"],
        "H-left": ["maximize", "leftHalf"], "H-right": ["maximize", "rightHalf"],
        "H-top": ["maximize", "topHalf"], "H-bottom": ["maximize", "bottomHalf"],
    }
    for name, seq in pos_actions.items():
        r = maxr
        for a in seq:
            res = resolve(a, r)
            r = tile(res)
        start_rects[name] = (seq, r)

    results = []
    idx = 0
    fails = []
    for start_name, (pos_seq, srect) in start_rects.items():
        for pressed in PRESSED:
            idx += 1
            for a in pos_seq:
                trigger(a)
            rep = trigger(pressed)
            label = f"{start_name} +{KEY_OF[pressed]}"
            if rep is None:
                print(f"[FAIL] {label} — no report")
                fails.append((label, "no report", None))
                results.append(False)
                continue
            expected_resolved = resolve(pressed, srect)
            ideal = tile(expected_resolved)
            actual = rep["frame"]
            note = f"resolved={rep['resolved']}"
            ok = rep["resolved"] == expected_resolved and close(actual, ideal)
            if not ok:
                # clamp tolerance: anchored to the right edges + inside frame
                ax, ay, aw, ah = actual
                ex, ey, ew, eh = ideal
                anchored = (abs(ax - ex) <= TOL or abs(ax + aw - ex - ew) <= TOL) and \
                           (abs(ay - ey) <= TOL or abs(ay + ah - ey - eh) <= TOL)
                inside = ax >= VX - 1 and ay >= VY - 1 and ax + aw <= VX + VW + 1 and ay + ah <= VY + VH + 1
                grew = aw >= ew - TOL and ah >= eh - TOL
                if anchored and inside and grew:
                    ok = True
                    note += " [clamped, pinned correctly]"
            status = "OK" if ok else "FAIL"
            print(f"[{status}] {label} -> {rep['resolved']:12s} actual=({actual[0]:.0f},{actual[1]:.0f},{actual[2]:.0f},{actual[3]:.0f}) expected={tuple(int(v) for v in ideal)} {note if not ok else ''}")
            results.append(ok)
            if not ok:
                fails.append((label, f"resolved={rep['resolved']} actual={actual}", ideal))
            render(idx, label, ideal, actual, ok, note)

    # montage
    pngs = sorted(f for f in os.listdir(OUT) if f.endswith(".png") and f[0].isdigit())
    imgs = [Image.open(os.path.join(OUT, f)) for f in pngs]
    if imgs:
        cols, w0, h0 = 3, *imgs[0].size
        rows = (len(imgs) + cols - 1) // cols
        board = Image.new("RGB", (w0 * cols + 16, (h0 + 8) * rows), (8, 8, 10))
        for k, im in enumerate(imgs):
            board.paste(im, ((k % cols) * (w0 + 8), (k // cols) * (h0 + 8)))
        board.save(f"{OUT}/montage.png")

    passed = sum(results)
    print(f"\n=== TRANSITION MATRIX: {passed}/{len(results)} PASS, {len(results)-passed} FAIL ===")
    if fails:
        print("failures:")
        for label, det, ideal in fails:
            print(f"  - {label}: {det} expected_tile={tuple(int(v) for v in ideal) if ideal else '?'}")
    print(f"montage: {OUT}/montage.png")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
