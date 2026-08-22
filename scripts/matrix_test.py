#!/usr/bin/env python3
"""Full movement-matrix test for Glass, driven through the real Swift logic
via `Glass --dump-resolve` (resolvedAction + layoutRect + pinnedRect).

Asserts, for every starting position x every action:
  1. resolved target lies fully inside the visible frame (bounded)
  2. quarter arrows slide exactly one column/row and CLAMP at edges (no wrap)
  3. halves/thirds/two-thirds are absolute picks
  4. re-picking the tile you're in is a no-op
  5. with an app-min clamp applied, pinnedRect keeps the window inside the
     visible frame and anchored to the correct corner
"""
import json
import os
import subprocess
import sys

PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(PROJ, ".build", "debug", "Glass")
TOL = 0.6

# Visible frame on the test machine (menu bar top, Dock bottom).
VX, VY, VW, VH = 0.0, 90.0, 1728.0, 994.0
VIS = (VX, VY, VW, VH)

PASS, FAIL = "PASS", "FAIL"
results = []


def record(name, ok, detail=""):
    results.append((ok, name, detail))
    print(f"[{PASS if ok else FAIL}] {name}" + (f" — {detail}" if detail and not ok else ""))


def resolve_all(cx, cy, cw, ch, clamp=None):
    args = [BIN, "--dump-resolve", str(cx), str(cy), str(cw), str(ch),
            str(VX), str(VY), str(VW), str(VH)]
    if clamp:
        args += [str(clamp[0]), str(clamp[1])]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    data = json.loads(out)
    # {"action=>resolved": {x,y,w,h,cx,cy}}
    result = {}
    for key, rect in data.items():
        action, resolved = key.split("=>")
        result[action] = {"resolved": resolved, **rect}
    return result


def close(a, b):
    return abs(a - b) <= TOL


def rect_matches(r, x, y, w, h):
    return all([close(r["x"], x), close(r["y"], y), close(r["w"], w), close(r["h"], h)])


def inside_visible(r):
    return (r["x"] >= VX - TOL and r["y"] >= VY - TOL
            and r["x"] + r["w"] <= VX + VW + TOL and r["y"] + r["h"] <= VY + VH + TOL)


def tile(name, col, row, cols=2, rows=2):
    """Cocoa rect of grid slot: col 0 = left, row 0 = bottom."""
    w = VW / cols
    h = VH / rows
    return (VX + col * w, VY + row * h, w, h)


def quarter(col, row):
    """Cocoa rect of a corner quadrant (half width x half height): col 0 = left,
    row 0 = bottom. Four quadrants tile the visible frame 2x2."""
    return (VX + col * (VW / 2.0), VY + row * (VH / 2.0), VW / 2.0, VH / 2.0)


QUARTERS = {
    "topLeft": (0, 1), "topRight": (1, 1),
    "bottomLeft": (0, 0), "bottomRight": (1, 0),
}
ARROW_OF = {"topLeft": "LEFT", "topRight": "RIGHT", "bottomLeft": "DOWN", "bottomRight": "UP"}
COLS = {"leftThird": 0, "centerThird": 1, "rightThird": 2}


def main():
    fails = 0

    # ---- Matrix 1: quarter arrows from each quarter ------------------------
    for start_name, (sc, sr) in QUARTERS.items():
        sx, sy, sw, sh = tile(start_name, sc, sr)
        table = resolve_all(sx, sy, sw, sh)
        for arrow_action, direction in [("topLeft", (-1, 0)), ("topRight", (1, 0)),
                                        ("bottomLeft", (0, -1)), ("bottomRight", (0, 1))]:
            r = table[arrow_action]
            exp_c = min(max(sc + direction[0], 0), 1)
            exp_r = min(max(sr + direction[1], 0), 1)
            exp_name = next(n for n, (c, rw) in QUARTERS.items() if (c, rw) == (exp_c, exp_r))
            ex, ey, ew, eh = quarter(exp_c, exp_r)
            ok = r["resolved"] == exp_name and rect_matches(r, ex, ey, ew, eh)
            record(f"quarter {start_name} + {ARROW_OF[arrow_action]:5s} -> {exp_name}",
                   ok, f"got resolved={r['resolved']} rect=({r['x']},{r['y']},{r['w']},{r['h']})")
            if not ok:
                fails += 1
            if not inside_visible(r):
                record(f"quarter {start_name} bounded", False, str(r))
                fails += 1

    # ---- Matrix 2: quarter arrows from a half / maximized ------------------
    starts = {
        "maximize": (VX, VY, VW, VH),
        "leftHalf": tile("L", 0, 0, 2, 1),
        "rightHalf": tile("R", 1, 0, 2, 1),
        "topHalf": tile("T", 0, 1, 1, 2),
        "bottomHalf": tile("B", 0, 0, 1, 2),
    }
    for start_name, (sx, sy, sw, sh) in starts.items():
        table = resolve_all(sx, sy, sw, sh)
        mid_x_of_start = sx + sw / 2
        mid_y_of_start = sy + sh / 2
        for arrow_action in QUARTERS:
            r = table[arrow_action]
            # expected quadrant from window center
            c = 0 if mid_x_of_start <= VX + VW / 2 else 1
            rw = 0 if mid_y_of_start <= VY + VH / 2 else 1
            d = {"topLeft": (-1, 0), "topRight": (1, 0), "bottomLeft": (0, -1), "bottomRight": (0, 1)}[arrow_action]
            ec = min(max(c + d[0], 0), 1)
            er = min(max(rw + d[1], 0), 1)
            exp_name = next(n for n, (cc, rr) in QUARTERS.items() if (cc, rr) == (ec, er))
            ex, ey, ew, eh = quarter(ec, er)
            ok = r["resolved"] == exp_name and rect_matches(r, ex, ey, ew, eh) and inside_visible(r)
            record(f"{start_name} + shift-{ARROW_OF[arrow_action]} -> {exp_name}", ok,
                   f"got resolved={r['resolved']} rect=({r['x']},{r['y']},{r['w']},{r['h']})")
            if not ok:
                fails += 1

    # ---- Matrix 3: halves/thirds absolute; self-pick no-op -----------------
    absolutes = {
        "leftHalf": tile("L", 0, 0, 2, 1),
        "rightHalf": tile("R", 1, 0, 2, 1),
        "topHalf": tile("T", 0, 1, 1, 2),
        "bottomHalf": tile("B", 0, 0, 1, 2),
        "leftThird": None, "centerThird": None, "rightThird": None,
        "leftTwoThirds": None, "rightTwoThirds": None,
        "maximize": (VX, VY, VW, VH),
    }
    tw = VW / 3
    absolutes["leftThird"] = (VX, VY, tw, VH)
    absolutes["centerThird"] = (VX + tw, VY, tw, VH)
    absolutes["rightThird"] = (VX + 2 * tw, VY, VW - 2 * tw, VH)
    absolutes["leftTwoThirds"] = (VX, VY, VW - tw, VH)
    absolutes["rightTwoThirds"] = (VX + tw, VY, VW - tw, VH)

    for action, (ax, ay, aw, ah) in absolutes.items():
        # from every other start, picking is absolute
        for start_name, (sx, sy, sw, sh) in starts.items():
            table = resolve_all(sx, sy, sw, sh)
            r = table[action]
            ok = r["resolved"] == action and rect_matches(r, ax, ay, aw, ah)
            if not ok:
                record(f"{start_name} + {action} -> absolute", False,
                       f"got resolved={r['resolved']} rect=({r['x']},{r['y']},{r['w']},{r['h']}) expected=({ax},{ay},{aw},{ah})")
                fails += 1
        # self-pick is a no-op (same rect back)
        table = resolve_all(ax, ay, aw, ah)
        r = table[action]
        ok = r["resolved"] == action and rect_matches(r, ax, ay, aw, ah)
        record(f"{action} self-pick no-op", ok, f"got rect=({r['x']},{r['y']},{r['w']},{r['h']})")
        if not ok:
            fails += 1

    # ---- Matrix 4: app-min clamp pinning -----------------------------------
    # An app that refuses to shrink below 864x560 (the user's real case).
    CLAMP = (864.0, 560.0)
    cases = [
        ("topLeft", (0, 832, 554, 252), (VX, VY + VH - 560, 864, 560)),      # flush top-left
        ("topRight", (1296, 832, 432, 252), (VX + VW - 864, VY + VH - 560, 864, 560)),
        ("bottomLeft", (0, 90, 554, 252), (VX, VY, 864, 560)),
        ("bottomRight", (0, 90, 432, 248.5), (VX + VW - 864, VY, 864, 560), "topRight"),  # -> from bottom-left
        ("topHalf", (0, 90, 1728, 993), (VX + (VW - 864) / 2, VY + VH - 560, 864, 560)),   # width-clamped -> centered
        ("bottomHalf", (0, 587, 1728, 497), (VX + (VW - 864) / 2, VY, 864, 560)),
        ("rightHalf", (1296, 90, 432, 993), (VX + VW - 864, VY + (VH - 560) / 2, 864, 560)),
        ("leftHalf", (0, 90, 432, 993), (VX, VY + (VH - 560) / 2, 864, 560)),
    ]
    for case in cases:
        action, start, expected = case[0], case[1], case[2]
        pressed = case[3] if len(case) > 3 else action
        ex, ey, ew, eh = expected
        table = resolve_all(*start, clamp=CLAMP)
        r = table[pressed]
        ok = r["resolved"] == action and rect_matches(r, ex, ey, ew, eh) and inside_visible(r)
        record(f"clamp-pin {action} (app min 864x560)", ok,
               f"got rect=({r['x']},{r['y']},{r['w']},{r['h']}) expected=({ex},{ey},{ew},{eh})")
        if not ok:
            fails += 1

    total = len(results)
    print(f"\n=== MATRIX: {total - fails}/{total} PASS, {fails} FAIL ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
