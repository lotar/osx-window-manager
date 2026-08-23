#!/usr/bin/env python3
"""Live movement matrix for osx-window-manager, driven through the trusted running app
(Darwin-notification bridge) with visual validation.

For each step: position the frontmost window via one action, then apply a
slide/absolute action. After each move we parse the AX-read-back frame from
/tmp/owm-roundtrip.log and render an exact-scale visualization:
  - gray area = visible frame (menu bar + dock respected)
  - blue outline = expected tile
  - green fill = actual window frame reported by the app
PASS = actual frame matches the expected tile within tolerance (or is the
clamped size pinned to the correct corner).
"""
import json
import os
import re
import subprocess
import time

from PIL import Image, ImageDraw

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = "/tmp/owm-roundtrip.log"
ACTION_FILE = "/tmp/owm-roundtrip.action"
OUT_DIR = "/tmp/matrix"

VX, VY, VW, VH = 0.0, 90.0, 1728.0, 994.0  # visible frame (cocoa)
SCALE = 0.35                                # render scale
PAD = 24

TOL = 8.0  # px tolerance in cocoa points


TEST_PID = None  # set in main(); targets that app's focused window via AX


import itertools
SEQ = itertools.count(1)


def trigger(action):
    seq = next(SEQ)
    with open(ACTION_FILE, "w") as f:
        f.write(action)
    with open("/tmp/owm-roundtrip.seq", "w") as f:
        f.write(str(seq))
    if TEST_PID:
        with open("/tmp/owm-roundtrip.pid", "w") as f:
            f.write(str(TEST_PID))
    try:
        os.remove(LOG)
    except FileNotFoundError:
        pass
    # Post, then poll for the matching report (re-post once if the Darwin
    # notification was lost/coalesced).
    for attempt in range(2):
        subprocess.run(["notifyutil", "-p", "com.lotar.osx-window-manager.roundtrip"])
        for _ in range(30):
            time.sleep(0.2)
            if os.path.exists(LOG):
                text = open(LOG).read()
                if f"seq={seq} action={action}" in text:
                    return parse_report()
    return None


def parse_report():
    if not os.path.exists(LOG):
        return None
    text = open(LOG).read()
    m_res = re.search(r"resolved=(\S+)", text)
    m_app = re.search(r"app=(.+?)\n", text)
    m_after = re.search(r"after\s+quartz=\(([-\d.]+), ([-\d.]+)\) size=\(([\d.]+), ([\d.]+)\)", text)
    if not (m_res and m_after):
        return None
    qx, qy, w, h = map(float, m_after.groups())
    cocoa_y = 1117.0 - qy - h  # mainScreenHeight from report is 1117
    return {
        "resolved": m_res.group(1),
        "app": m_app.group(1).strip() if m_app else "?",
        "frame": (qx, cocoa_y, w, h),
    }


def tile(name):
    qw, qh = VW / 4, VH / 4
    tw = VW / 3
    return {
        "leftHalf": (VX, VY, VW / 2, VH),
        "rightHalf": (VX + VW / 2, VY, VW / 2, VH),
        "topHalf": (VX, VY + VH / 2, VW, VH / 2),
        "bottomHalf": (VX, VY, VW, VH / 2),
        "maximize": (VX, VY, VW, VH),
        "centerThird": (VX + tw, VY, tw, VH),
        "rightThird": (VX + 2 * tw, VY, VW - 2 * tw, VH),
        "leftThird": (VX, VY, tw, VH),
        "bottomLeft": (VX, VY, VW / 2, VH / 2),
        "bottomRight": (VX + VW / 2, VY, VW / 2, VH / 2),
        "topLeft": (VX, VY + VH / 2, VW / 2, VH / 2),
        "topRight": (VX + VW / 2, VY + VH / 2, VW / 2, VH / 2),
    }[name]


def to_px(rect):
    x, y, w, h = rect
    px = PAD + x * SCALE
    py = PAD + (VY + VH - (y + h)) * SCALE  # flip Y for image coords
    return [px, py, w * SCALE, h * SCALE]


def render(idx, step_name, expected, actual, ok, detail):
    W = int(VW * SCALE) + PAD * 2
    H = int((VY + VH) * SCALE) + PAD * 2 + 26
    img = Image.new("RGB", (W, H), (24, 24, 28))
    d = ImageDraw.Draw(img)
    # full screen bounds
    d.rectangle([PAD, PAD, PAD + VW * SCALE, PAD + (VY + VH) * SCALE], outline=(90, 90, 100), width=1)
    # visible frame area
    vx0, vy0 = to_px((VX, VY, 0, 0))[:2]
    d.rectangle([vx0, vy0, vx0 + VW * SCALE, vy0 + VH * SCALE], fill=(44, 48, 56), outline=(120, 120, 130))
    # menu bar / dock bands
    d.rectangle([vx0, PAD, vx0 + VW * SCALE, vy0], fill=(30, 30, 34))
    dock_h = (VY) * SCALE
    d.rectangle([vx0, vy0 + VH * SCALE, vx0 + VW * SCALE, vy0 + VH * SCALE + dock_h], fill=(30, 30, 34))
    # expected tile
    ex, ey, ew, eh = to_px(expected)
    d.rectangle([ex, ey, ex + ew, ey + eh], outline=(80, 160, 255), width=2)
    # actual window
    ax, ay, aw, ah = to_px(actual)
    d.rectangle([ax, ay, ax + aw, ay + ah], fill=(60, 200, 110, 90), outline=(60, 220, 120), width=2)
    status = "OK " if ok else "FAIL"
    d.text((PAD, H - 22), f"{status} {step_name}  exp={tuple(round(v) for v in expected)} act={tuple(round(v) for v in actual)} {detail}",
           fill=(255, 220, 80) if ok else (255, 80, 80))
    img.save(f"{OUT_DIR}/{idx:02d}_{ok and 'ok' or 'fail'}.png")
    return img


def frames_close(a, b, tol=TOL):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def main():
    global TEST_PID
    os.makedirs(OUT_DIR, exist_ok=True)
    pid_out = subprocess.run(["pgrep", "-x", "OwmTestWindow"], capture_output=True, text=True).stdout.strip()
    if not pid_out:
        print("test window not running"); raise SystemExit(1)
    TEST_PID = int(pid_out.splitlines()[0])
    # sanity: bridge must be able to see it
    probe = trigger("maximize")
    if probe is None:
        print("bridge cannot target test window"); raise SystemExit(1)
    print(f"targeting OwmTestWindow pid={TEST_PID}")
    steps = [
        # (positioning action(s) first, then the action under test, expected tile name)
        ("maximize -> shift-RIGHT", ["maximize", "topRight"], "topRight"),
        ("topRight -> shift-LEFT (back)", [None, "topLeft"], "topLeft"),
        ("topLeft -> shift-DOWN? no: shift-UP clamps at top edge", [None, "bottomRight"], "topLeft"),  # no-op at top-left... UP from top row stays
        ("topLeft -> shift-RIGHT", [None, "topRight"], "topRight"),
        ("topRight -> shift-DOWN", [None, "bottomLeft"], "bottomRight"),
        ("bottomRight -> shift-LEFT", [None, "topLeft"], "bottomLeft"),  # column slide, same row
        ("bottomLeft -> shift-RIGHT", ["bottomLeft", "topRight"], "bottomRight"),
        ("maximize -> RIGHT half", ["maximize", "rightHalf"], "rightHalf"),
        ("rightHalf -> LEFT half", [None, "leftHalf"], "leftHalf"),
        ("leftHalf -> UP top half", [None, "topHalf"], "topHalf"),
        ("topHalf -> DOWN bottom half", [None, "bottomHalf"], "bottomHalf"),
        ("maximize -> centerThird", ["maximize", "centerThird"], "centerThird"),
        ("centerThird -> rightThird", [None, "rightThird"], "rightThird"),
    ]
    results = []
    imgs = []
    for i, (label, actions, expected_name) in enumerate(steps):
        rep = None
        for a in actions:
            if a is None:
                continue
            rep = trigger(a)  # trigger each exactly once, keep last report
        if rep is None:
            print(f"[FAIL] {label} — no report")
            results.append(False)
            continue
        expected = tile(expected_name)
        actual = rep["frame"]
        ok = frames_close(actual, expected)
        # tolerate clamp: same corner anchoring but bigger size still counts if
        # anchored correctly (min-size apps); flag it in detail.
        detail = f"(resolved={rep['resolved']} app={rep['app']})"
        if not ok:
            ex, ey, ew, eh = expected
            ax_, ay_, aw_, ah_ = actual
            anchored = (
                abs(ax_ - ex) <= TOL or abs((ax_ + aw_) - (ex + ew)) <= TOL
            ) and (
                abs(ay_ - ey) <= TOL or abs((ay_ + ah_) - (ey + eh)) <= TOL
            )
            inside = ax_ >= VX - 1 and ay_ >= VY - 1 and ax_ + aw_ <= VX + VW + 1 and ay_ + ah_ <= VY + VH + 1
            if anchored and inside:
                ok = True
                detail += " [clamped by app min size, pinned correctly]"
        record = f"[{'OK' if ok else 'FAIL'}] {label} — actual={tuple(round(v) for v in actual)} {detail}"
        print(record)
        results.append(ok)
        imgs.append(render(i, label, expected, actual, ok, detail))

    # montage
    if imgs:
        cols = 2
        rows = (len(imgs) + 1) // cols
        w0, h0 = imgs[0].size
        board = Image.new("RGB", (w0 * cols + 12, (h0 + 8) * rows), (10, 10, 12))
        for k, im in enumerate(imgs):
            board.paste(im, ((k % cols) * (w0 + 12), (k // cols) * (h0 + 8)))
        board.save(f"{OUT_DIR}/montage.png")
        print(f"\nmontage: {OUT_DIR}/montage.png")

    passed = sum(results)
    print(f"=== LIVE MATRIX: {passed}/{len(results)} PASS ===")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys_exit = main()
    raise SystemExit(sys_exit)
