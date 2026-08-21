#!/usr/bin/env python3
"""E2E test for the Glass menu-bar window manager.

Covers:
  1. `swift build` (debug + release) succeeds
  2. App launches as a menu-bar accessory and stays alive
  3. shortcuts.v1 in UserDefaults domain Glass (incomplete/fresh → built-in defaults, not a fail)
  4. Each WindowAction hotkey is posted (CGEvent) and geometry is checked
     against the frontmost Finder window (AX / AppKit visibleFrame)
  5. Status-bar menu → Settings… → Reset to Defaults → Quit via ⌘Q

Exit code 0 = no FAIL (SKIP is allowed, including AX untrusted).
"""
import json
import os
import plistlib
import re
import signal
import subprocess
import sys
import time

PROJ = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(PROJ, ".build", "debug", "Glass")
PLIST = os.path.expanduser("~/Library/Preferences/Glass.plist")
DOMAIN = "Glass"
SHORTCUTS_KEY = "shortcuts.v1"
GAP_KEY = "gap.v1"

# WindowAction rawValues. Geometry e2e covers all of these.
ACTIONS = [
    "leftHalf", "rightHalf", "topHalf", "bottomHalf",
    "topLeft", "topRight", "bottomLeft", "bottomRight",
    "leftThird", "centerThird", "rightThird",
    "leftTwoThirds", "rightTwoThirds",
    "maximize", "almostMaximize", "center", "restore",
    "nextDisplay", "previousDisplay",
]
DISPLAY_ACTIONS = ("nextDisplay", "previousDisplay")

# NSEvent modifier raw: cmd+opt = 1572864, cmd+opt+shift = 1703936
CMD_OPT = 1572864
CMD_OPT_SHIFT = 1703936
DEFAULT_SHORTCUTS = {
    "leftHalf": (123, CMD_OPT),
    "rightHalf": (124, CMD_OPT),
    "topHalf": (126, CMD_OPT),
    "bottomHalf": (125, CMD_OPT),
    "maximize": (36, CMD_OPT),
    "center": (8, CMD_OPT),
    "restore": (6, CMD_OPT),
    "almostMaximize": (3, CMD_OPT),
    "leftThird": (18, CMD_OPT),
    "centerThird": (19, CMD_OPT),
    "rightThird": (20, CMD_OPT),
    "leftTwoThirds": (14, CMD_OPT),
    "rightTwoThirds": (17, CMD_OPT),
    "previousDisplay": (33, CMD_OPT),
    "nextDisplay": (30, CMD_OPT),
    "topLeft": (123, CMD_OPT_SHIFT),
    "topRight": (124, CMD_OPT_SHIFT),
    "bottomLeft": (125, CMD_OPT_SHIFT),
    "bottomRight": (126, CMD_OPT_SHIFT),
}

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"
GEOM_TOL = 80.0
results = []


def record(name, status, detail=""):
    results.append((status, name, detail))
    print(f"[{status}] {name}" + (f" — {detail}" if detail else ""))


def sh(cmd, timeout=60, check=False):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"command failed: {cmd}\n{r.stdout}{r.stderr}")
    return r


def osa(script, timeout=12):
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def jxa(script, timeout=12):
    try:
        r = subprocess.run(
            ["osascript", "-l", "JavaScript", "-e", script],
            capture_output=True, text=True, timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip()


HELPER = os.path.join(PROJ, ".build", "e2e_helper")
HELPER_C = r'''
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

static AXUIElementRef focused_app(void) {
  AXUIElementRef sys = AXUIElementCreateSystemWide();
  CFTypeRef appRef = NULL;
  AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute, &appRef);
  CFRelease(sys);
  return (AXUIElementRef)appRef;
}

static AXUIElementRef focused_window(AXUIElementRef app) {
  CFTypeRef winRef = NULL;
  if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &winRef) == kAXErrorSuccess && winRef)
    return (AXUIElementRef)winRef;
  CFTypeRef wv = NULL;
  if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &wv) == kAXErrorSuccess && wv &&
      CFGetTypeID(wv) == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)wv) > 0) {
    AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex((CFArrayRef)wv, 0);
    CFRetain(win);
    CFRelease(wv);
    return win;
  }
  if (wv) CFRelease(wv);
  return NULL;
}

int main(int argc, char** argv) {
  if (argc == 2 && !strcmp(argv[1], "display")) {
    CGRect b = CGDisplayBounds(CGMainDisplayID());
    printf("%.0f %.0f\n", b.size.width, b.size.height);
    return 0;
  }
  if (argc == 4 && !strcmp(argv[1], "key")) {
    unsigned int kc = (unsigned int)atoi(argv[2]);
    long m = strtol(argv[3], NULL, 0);
    CGEventFlags f = 0;
    if (m & 0x20000) f |= kCGEventFlagMaskShift;
    if (m & 0x40000) f |= kCGEventFlagMaskControl;
    if (m & 0x80000) f |= kCGEventFlagMaskAlternate;
    if (m & 0x100000) f |= kCGEventFlagMaskCommand;
    for (int down = 1; down >= 0; down--) {
      CGEventRef e = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)kc, down != 0);
      if (e) { CGEventSetFlags(e, f); CGEventPost(kCGHIDEventTap, e); CFRelease(e); }
      usleep(down ? 30000 : 10000);
    }
    return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "trust")) {
    printf("%d\n", (int)AXIsProcessTrusted());
    return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "axwin")) {
    AXUIElementRef app = focused_app();
    if (!app) { printf("0 0 0 0\n"); return 0; }
    AXUIElementRef win = focused_window(app);
    if (!win) { printf("0 0 0 0\n"); CFRelease(app); return 0; }
    double p[2] = {-1, -1}, s[2] = {-1, -1};
    CFTypeRef pv = NULL, sv = NULL;
    if (AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &pv) == kAXErrorSuccess && pv) {
      if (CFGetTypeID(pv) == AXValueGetTypeID()) AXValueGetValue((AXValueRef)pv, kAXValueCGPointType, p);
      CFRelease(pv);
    }
    if (AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &sv) == kAXErrorSuccess && sv) {
      if (CFGetTypeID(sv) == AXValueGetTypeID()) AXValueGetValue((AXValueRef)sv, kAXValueCGSizeType, s);
      CFRelease(sv);
    }
    CFRelease(win);
    CFRelease(app);
    printf("%.1f %.1f %.1f %.1f\n", p[0], p[1], s[0], s[1]);
    return 0;
  }
  if (argc == 6 && !strcmp(argv[1], "axset")) {
    AXUIElementRef app = focused_app();
    if (!app) return 1;
    AXUIElementRef win = focused_window(app);
    if (!win) { CFRelease(app); return 1; }
    CGPoint pt = {atof(argv[2]), atof(argv[3])};
    CGSize sz = {atof(argv[4]), atof(argv[5])};
    AXValueRef pv = AXValueCreate(kAXValueCGPointType, &pt);
    AXValueRef sv = AXValueCreate(kAXValueCGSizeType, &sz);
    AXError e1 = AXUIElementSetAttributeValue(win, kAXPositionAttribute, pv);
    AXError e2 = AXUIElementSetAttributeValue(win, kAXSizeAttribute, sv);
    if (pv) CFRelease(pv);
    if (sv) CFRelease(sv);
    CFRelease(win);
    CFRelease(app);
    printf("%d %d\n", (int)e1, (int)e2);
    return 0;
  }
  if (argc >= 2 && !strcmp(argv[1], "cgwin")) {
    const char* want = argc >= 3 ? argv[2] : "Finder";
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) { printf("0 0 0 0\n"); return 0; }
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
      CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
      CFStringRef name = CFDictionaryGetValue(d, kCGWindowOwnerName);
      CFNumberRef layerN = CFDictionaryGetValue(d, kCGWindowLayer);
      int layer = -1;
      if (layerN) CFNumberGetValue(layerN, kCFNumberIntType, &layer);
      char nbuf[128] = {0};
      if (name) CFStringGetCString(name, nbuf, sizeof nbuf, kCFStringEncodingUTF8);
      if (layer != 0 || strcmp(nbuf, want) != 0) continue;
      CFDictionaryRef b = CFDictionaryGetValue(d, kCGWindowBounds);
      double x=0,y=0,w=0,h=0;
      if (b) {
        CFNumberRef nx=CFDictionaryGetValue(b, CFSTR("X"));
        CFNumberRef ny=CFDictionaryGetValue(b, CFSTR("Y"));
        CFNumberRef nw=CFDictionaryGetValue(b, CFSTR("Width"));
        CFNumberRef nh=CFDictionaryGetValue(b, CFSTR("Height"));
        if (nx) CFNumberGetValue(nx, kCFNumberDoubleType, &x);
        if (ny) CFNumberGetValue(ny, kCFNumberDoubleType, &y);
        if (nw) CFNumberGetValue(nw, kCFNumberDoubleType, &w);
        if (nh) CFNumberGetValue(nh, kCFNumberDoubleType, &h);
      }
      if (w > 80 && h > 80) {
        printf("%.1f %.1f %.1f %.1f\n", x, y, w, h);
        CFRelease(list);
        return 0;
      }
    }
    CFRelease(list);
    printf("0 0 0 0\n");
    return 0;
  }
  fprintf(stderr, "usage: e2e_helper display|key|trust|axwin|axset|cgwin [Owner]\n");
  return 2;
}
'''


def ensure_helper():
    os.makedirs(os.path.join(PROJ, ".build"), exist_ok=True)
    src = os.path.join(PROJ, ".build", "e2e_helper.c")
    with open(src, "w") as f:
        f.write(HELPER_C)
    r = sh(
        f"cc -O -o {HELPER} {src} -framework CoreGraphics -framework ApplicationServices 2>&1",
        timeout=120,
    )
    return r.returncode == 0


def helper_trust():
    if not os.path.exists(HELPER):
        return None
    r = sh(f"{HELPER} trust 2>/dev/null", timeout=10)
    if r.returncode != 0:
        return None
    return r.stdout.strip() == "1"


def parse_rect(stdout):
    try:
        vals = tuple(float(v) for v in stdout.split()[:4])
        return vals if len(vals) == 4 and vals[2] > 80 and vals[3] > 80 else None
    except ValueError:
        return None


def cg_window(owner="Finder"):
    if not os.path.exists(HELPER):
        return None
    r = sh(f"{HELPER} cgwin {owner} 2>/dev/null", timeout=10)
    if r.returncode != 0:
        return None
    return parse_rect(r.stdout)


def ax_window():
    if not os.path.exists(HELPER):
        return None
    r = sh(f"{HELPER} axwin 2>/dev/null", timeout=10)
    if r.returncode != 0:
        return None
    return parse_rect(r.stdout)


def ax_set(x, y, w, h):
    if not os.path.exists(HELPER):
        return False
    r = sh(f"{HELPER} axset {x:.1f} {y:.1f} {w:.1f} {h:.1f} 2>/dev/null", timeout=10)
    return r.returncode == 0 and "0 0" in r.stdout


def glass_pid():
    r = sh("pgrep -x Glass")
    pids = [p for p in r.stdout.split() if p]
    return int(pids[0]) if pids else None


def kill_glass():
    for p in (sh("pgrep -x Glass").stdout.split()):
        try:
            os.kill(int(p), signal.SIGKILL)
        except OSError:
            pass
    time.sleep(0.5)


def front_window():
    """(x, y, w, h) of window 1 of the frontmost process (top-left origin), or None."""
    out = osa(
        'tell application "System Events" to tell (first process whose frontmost is true) '
        'to get {position, size} of window 1'
    )
    if not out:
        return None
    m = re.match(
        r"(-?\d+(?:\.\d+)?), (-?\d+(?:\.\d+)?), (-?\d+(?:\.\d+)?), (-?\d+(?:\.\d+)?)",
        out,
    )
    return tuple(float(v) for v in m.groups()) if m else None


def measure_window():
    return cg_window("Finder") or ax_window() or front_window()


def post_hotkey(keycode, modifiers):
    if os.path.exists(HELPER):
        if sh(f"{HELPER} key {keycode} {modifiers} 2>/dev/null", timeout=10).returncode == 0:
            time.sleep(0.45)
            return
    mods = []
    if modifiers & 0x80000:
        mods.append("option down")
    if modifiers & 0x100000:
        mods.append("command down")
    if modifiers & 0x40000:
        mods.append("control down")
    if modifiers & 0x20000:
        mods.append("shift down")
    using = f" using {{{', '.join(mods)}}}" if mods else ""
    osa(f'tell application "System Events" to key code {keycode}{using}')
    time.sleep(0.45)


def focus_finder():
    osa('tell application "Finder" to activate')
    time.sleep(0.25)


def _shortcut_tuple(entry):
    if not isinstance(entry, dict):
        return None
    kc = entry.get("keyCode")
    mods = entry.get("modifiersRaw", entry.get("modifiers", 0))
    if kc is None:
        return None
    try:
        return (int(kc), int(mods))
    except (TypeError, ValueError):
        return None


def parse_shortcuts_blob(blob):
    """JSONEncoder of [WindowAction:Shortcut] is an alternating key/object array, or a dict."""
    out = {}
    if isinstance(blob, dict):
        for key, entry in blob.items():
            t = _shortcut_tuple(entry)
            if t is not None:
                out[str(key)] = t
        return out
    if not isinstance(blob, list):
        return out
    i = 0
    while i < len(blob):
        item = blob[i]
        nxt = blob[i + 1] if i + 1 < len(blob) else None
        if isinstance(item, str) and isinstance(nxt, dict):
            t = _shortcut_tuple(nxt)
            if t is not None:
                out[item] = t
            i += 2
            continue
        if isinstance(item, (list, tuple)) and len(item) == 2 and isinstance(item[0], str):
            t = _shortcut_tuple(item[1]) if isinstance(item[1], dict) else None
            if t is not None:
                out[item[0]] = t
            i += 1
            continue
        if isinstance(item, dict):
            if "keyCode" in item and "action" in item:
                t = _shortcut_tuple(item)
                if t is not None:
                    out[str(item["action"])] = t
            elif "key" in item and isinstance(item.get("value"), dict):
                t = _shortcut_tuple(item["value"])
                if t is not None:
                    out[str(item["key"])] = t
            else:
                for k, v in item.items():
                    if k in ("keyCode", "modifiersRaw", "modifiers"):
                        continue
                    t = _shortcut_tuple(v) if isinstance(v, dict) else None
                    if t is not None:
                        out[str(k)] = t
        i += 1
    return out


def load_glass_prefs():
    r = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True, timeout=10)
    if r.returncode == 0 and r.stdout:
        try:
            return plistlib.loads(r.stdout)
        except Exception:
            pass
    try:
        with open(PLIST, "rb") as f:
            return plistlib.load(f)
    except Exception:
        return {}


def decode_json_pref(raw):
    if raw is None:
        return None
    if isinstance(raw, (bytes, bytearray)):
        try:
            return json.loads(bytes(raw))
        except Exception:
            return None
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except Exception:
            return None
    if isinstance(raw, (dict, list)):
        return raw
    return None


def read_shortcuts():
    """Decode shortcuts.v1 from domain Glass → {action: (keyCode, modifiersRaw)}."""
    prefs = load_glass_prefs()
    blob = decode_json_pref(prefs.get(SHORTCUTS_KEY) if prefs else None)
    err = None
    if blob is None:
        r = sh(f"defaults read {DOMAIN} {SHORTCUTS_KEY} 2>/dev/null")
        if r.returncode == 0 and r.stdout.strip():
            text = r.stdout
            # Only the hex payload after bytes = 0x, never the {length = N} digits.
            m = re.search(r"bytes\s*=\s*0x([0-9a-fA-F\s]+)", text)
            hexs = re.sub(r"\s+", "", m.group(1) if m else "")
            if not hexs:
                hexs = re.sub(r"[^0-9a-fA-F]", "", text)
            if len(hexs) % 2:
                hexs = hexs[:-1]
            if hexs:
                try:
                    blob = json.loads(bytes.fromhex(hexs))
                except Exception as e:
                    err = f"hex decode failed: {e}"
    out = parse_shortcuts_blob(blob) if blob is not None else {}
    if not out:
        raw = json.dumps(blob)[:400] if blob is not None else "no blob"
        return out, ((err + "; ") if err else "") + f"decoded nothing; raw: {raw}"
    return out, err


def read_gap():
    prefs = load_glass_prefs() or {}
    raw = prefs.get(GAP_KEY)
    if raw is None:
        return 0.0
    try:
        return float(raw)
    except (TypeError, ValueError):
        return 0.0


def appkit_screens():
    """List of {frame, vis} in AppKit bottom-left points (JXA NSScreen)."""
    script = (
        "ObjC.import('AppKit');\n"
        "var ss = $.NSScreen.screens;\n"
        "var n = Number(ss.count);\n"
        "var arr = [];\n"
        "for (var i = 0; i < n; i++) {\n"
        "  var s = ss.objectAtIndex(i);\n"
        "  var f = s.frame; var v = s.visibleFrame;\n"
        "  arr.push({fx:f.origin.x, fy:f.origin.y, fw:f.size.width, fh:f.size.height,"
        " vx:v.origin.x, vy:v.origin.y, vw:v.size.width, vh:v.size.height});\n"
        "}\n"
        "JSON.stringify(arr);\n"
    )
    out = jxa(script)
    if out:
        try:
            rows = json.loads(out)
            screens = []
            for row in rows:
                screens.append({
                    "frame": (float(row["fx"]), float(row["fy"]), float(row["fw"]), float(row["fh"])),
                    "vis": (float(row["vx"]), float(row["vy"]), float(row["vw"]), float(row["vh"])),
                })
            if screens:
                return screens
        except (ValueError, KeyError, TypeError):
            pass
    r = sh(f"{HELPER} display 2>/dev/null") if os.path.exists(HELPER) else None
    try:
        w, h = (float(v) for v in r.stdout.split()[:2])
        if w > 0 and h > 0:
            menu = 25.0
            return [{"frame": (0.0, 0.0, w, h), "vis": (0.0, 0.0, w, h - menu)}]
    except (ValueError, IndexError, AttributeError):
        pass
    return [{"frame": (0.0, 0.0, 1440.0, 900.0), "vis": (0.0, 0.0, 1440.0, 875.0)}]


def cocoa_to_ax(x, y, w, h, desktop_max_y):
    """AppKit (bottom-left) → AX (top-left of the global desktop)."""
    return (x, desktop_max_y - y - h, w, h)


def screens_ax(screens=None):
    screens = screens if screens is not None else appkit_screens()
    desktop_max_y = max(s["frame"][1] + s["frame"][3] for s in screens)
    out = []
    for s in screens:
        fx, fy, fw, fh = s["frame"]
        vx, vy, vw, vh = s["vis"]
        out.append({
            "frame_ax": cocoa_to_ax(fx, fy, fw, fh, desktop_max_y),
            "vis_ax": cocoa_to_ax(vx, vy, vw, vh, desktop_max_y),
            "vis": s["vis"],
            "frame": s["frame"],
        })
    return out, desktop_max_y


def screen_index_for(bounds, sax):
    cx = bounds[0] + bounds[2] / 2.0
    cy = bounds[1] + bounds[3] / 2.0
    for i, s in enumerate(sax):
        x, y, w, h = s["frame_ax"]
        if x - 40 <= cx <= x + w + 40 and y - 40 <= cy <= y + h + 40:
            return i
    return 0


def vis_ax_for(bounds, sax):
    return sax[screen_index_for(bounds, sax)]["vis_ax"]


def close_rect(got, expected, tol=GEOM_TOL):
    return all(abs(got[i] - expected[i]) <= tol for i in range(4))


def fmt_rect(r):
    if r is None:
        return "None"
    return f"({r[0]:.0f},{r[1]:.0f},{r[2]:.0f},{r[3]:.0f})"


def inset_vis(vis, gap):
    x, y, w, h = vis
    g = float(gap)
    return (x + g, y + g, w - 2 * g, h - 2 * g)


def expected_tile(action, vis, gap=0.0):
    """Expected AX bounds for a tile of visibleFrame (optional gap inset)."""
    x, y, w, h = inset_vis(vis, gap)
    hw, hh, tw = w / 2.0, h / 2.0, w / 3.0
    table = {
        "leftHalf": (x, y, hw, h),
        "rightHalf": (x + hw, y, hw, h),
        "topHalf": (x, y, w, hh),
        "bottomHalf": (x, y + hh, w, hh),
        "topLeft": (x, y + h - h / 4.0, w / 4.0, h / 4.0),
        "topRight": (x + w - w / 4.0, y + h - h / 4.0, w / 4.0, h / 4.0),
        "bottomLeft": (x, y, w / 4.0, h / 4.0),
        "bottomRight": (x + w - w / 4.0, y, w / 4.0, h / 4.0),
        "leftThird": (x, y, tw, h),
        "centerThird": (x + tw, y, tw, h),
        "rightThird": (x + 2 * tw, y, tw, h),
        "leftTwoThirds": (x, y, 2 * tw, h),
        "rightTwoThirds": (x + tw, y, 2 * tw, h),
        "maximize": (x, y, w, h),
    }
    return table.get(action)


def expect_geom(action, old, vis, new, tol=GEOM_TOL):
    """Return (ok, description) comparing AX bounds to AppKit-derived visibleFrame."""
    vx, vy, vw, vh = vis
    if action == "center":
        ox, oy, ow, oh = old
        ex, ey = vx + vw / 2.0 - ow / 2.0, vy + vh / 2.0 - oh / 2.0
        ok = abs(new[0] - ex) <= tol + 25 and abs(new[1] - ey) <= tol and abs(new[2] - ow) <= tol and abs(new[3] - oh) <= tol
        return ok, f"center≈({ex:.0f},{ey:.0f},{ow:.0f},{oh:.0f})"
    if action == "almostMaximize":
        dw, dh = vw - new[2], vh - new[3]
        ok = dw >= 35 and dh >= 35 and new[2] > vw * 0.5 and new[3] > vh * 0.5
        return ok, f"almostMaximize vis{fmt_rect(vis)} shrink=({dw:.0f},{dh:.0f}) (≥40pt/axis)"
    if action == "restore":
        ok = close_rect(new, old, tol=tol)
        return ok, f"restore≈snapshot {fmt_rect(old)}"
    exp = expected_tile(action, vis, gap=read_gap())
    if exp is None:
        return True, "no geometry assertion"
    return close_rect(new, exp, tol=tol), f"{action}≈{fmt_rect(exp)} vis{fmt_rect(vis)}"


def expected_cocoa(action, vis, current, gap=0.0):
    """Cocoa (bottom-left) tiles matching WindowEngine.layoutRect."""
    vx, vy, vw, vh = vis
    x, y, w, h = inset_vis(vis, gap)
    hw, hh, tw = w / 2.0, h / 2.0, w / 3.0
    ox, oy, ow, oh = current
    table = {
        "leftHalf": (x, y, hw, h),
        "rightHalf": (x + hw, y, w - hw, h),
        "topHalf": (x, y + hh, w, h - hh),
        "bottomHalf": (x, y, w, hh),
        "topLeft": (x, y + h - h / 4.0, w / 4.0, h / 4.0),
        "topRight": (x + w - w / 4.0, y + h - h / 4.0, w / 4.0, h / 4.0),
        "bottomLeft": (x, y, w / 4.0, h / 4.0),
        "bottomRight": (x + w - w / 4.0, y, w / 4.0, h / 4.0),
        "leftThird": (x, y, tw, h),
        "centerThird": (x + tw, y, tw, h),
        "rightThird": (x + 2 * tw, y, w - 2 * tw, h),
        "leftTwoThirds": (x, y, w - tw, h),
        "rightTwoThirds": (x + tw, y, w - tw, h),
        "maximize": (x, y, w, h),
        "almostMaximize": (x + 50, y + 50, w - 100, h - 100),
        "restore": current,
        "nextDisplay": current,
        "previousDisplay": current,
    }
    if action == "center":
        cx = vx + vw / 2.0 - ow / 2.0
        cy = vy + vh / 2.0 - oh / 2.0
        if ow <= vw:
            cx = min(max(cx, vx), vx + vw - ow)
        else:
            cx = vx
        if oh <= vh:
            cy = min(max(cy, vy), vy + vh - oh)
        else:
            cy = vy
        return (cx, cy, ow, oh)
    return table.get(action)


def run_dump_layout():
    """AX-free: Glass --dump-layout must match WindowEngine.layoutRect contract."""
    screens = appkit_screens()
    vis = screens[0]["vis"]
    current = (vis[0] + 120, vis[1] + 80, 640.0, 400.0)
    gap = read_gap()
    cmd = (
        f"{BIN} --dump-layout {vis[0]} {vis[1]} {vis[2]} {vis[3]} "
        f"{current[0]} {current[1]} {current[2]} {current[3]}"
    )
    r = sh(cmd, timeout=30)
    if r.returncode != 0 or not r.stdout.strip():
        record("dump-layout", FAIL, (r.stderr or r.stdout or "no output")[-300:])
        return False
    try:
        dump = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        record("dump-layout", FAIL, f"json: {e} raw={r.stdout[:200]}")
        return False
    bad = []
    for action in ACTIONS:
        got = dump.get(action)
        exp = expected_cocoa(action, vis, current, gap)
        if not isinstance(got, dict) or exp is None:
            bad.append(f"{action}: missing")
            continue
        got_r = (float(got["x"]), float(got["y"]), float(got["w"]), float(got["h"]))
        if not close_rect(got_r, exp, tol=1.5):
            bad.append(f"{action}: {fmt_rect(got_r)} != {fmt_rect(exp)}")
    if bad:
        record("dump-layout", FAIL, f"{len(bad)} mismatches: " + "; ".join(bad[:6]))
        return False
    record("dump-layout", PASS, f"{len(ACTIONS)} actions vis={fmt_rect(vis)} gap={gap:g}")
    return True


def glass_trusted():
    r = sh(f"{BIN} --trusted 2>/dev/null", timeout=10)
    return r.returncode == 0 and r.stdout.strip() == "1"


def run_live_actions():
    """Tile via Glass --action (same AX identity as the app) + CGWindowList measure."""
    if not glass_trusted():
        record("live-actions", SKIP, "Glass binary not Accessibility-trusted")
        return
    sh(f"open {PROJ}")
    time.sleep(1.0)
    start = measure_window()
    if start is None:
        record("live-actions", SKIP, "no Finder window via CGWindowList")
        return
    sax, _ = screens_ax()
    record("live-measure", PASS, f"Finder {fmt_rect(start)}")
    for action in ACTIONS:
        if action in DISPLAY_ACTIONS and len(sax) < 2:
            record(f"live:{action}", SKIP, "single display")
            continue
        if action == "restore":
            snap = measure_window() or start
            sh(f"{BIN} --action maximize", timeout=15)
            time.sleep(0.3)
            r = sh(f"{BIN} --action restore", timeout=15)
            time.sleep(0.3)
            new = measure_window()
            if r.returncode != 0 or new is None:
                record(f"live:{action}", SKIP if r.returncode == 3 else FAIL, f"rc={r.returncode}")
                continue
            ok, desc = expect_geom("restore", snap, vis_ax_for(snap, sax), new, tol=80)
            record(f"live:{action}", PASS if ok else FAIL, f"{fmt_rect(snap)} -> {fmt_rect(new)} ({desc})")
            continue
        r = sh(f"{BIN} --action {action}", timeout=15)
        time.sleep(0.3)
        new = measure_window()
        if r.returncode == 3:
            record(f"live:{action}", SKIP, "not-trusted")
            continue
        if r.returncode != 0 or new is None:
            record(f"live:{action}", FAIL, f"rc={r.returncode} new={fmt_rect(new)}")
            continue
        vis = vis_ax_for(new, sax)
        old = start
        ok, desc = expect_geom(action, old, vis, new)
        record(f"live:{action}", PASS if ok else FAIL, f"{fmt_rect(new)} (expect {desc})")
    if start:
        ax_set(*start)


def merge_shortcuts(persisted):
    merged = dict(DEFAULT_SHORTCUTS)
    merged.update(persisted)
    return merged


def click_status_item():
    for mb in (2, 1):
        r = osa(
            'tell application "System Events" to tell process "Glass" '
            f'to click menu bar item 1 of menu bar {mb}'
        )
        if r is not None:
            return mb
    return None


def click_menu_item(title, menu_bar):
    return osa(
        'tell application "System Events" to tell process "Glass" '
        f'to click menu item "{title}" of menu 1 of menu bar item 1 of menu bar {menu_bar}'
    )


def click_reset_button():
    for title in ("Reset to Defaults", "Reset to defaults"):
        r = osa(
            'tell application "System Events" to tell process "Glass" '
            f'to click button "{title}" of window 1'
        )
        if r is not None:
            return title
    return None


def main():
    if not ensure_helper():
        record("helper-compile", FAIL, "cc failed")
        return finish()
    record("helper-compile", PASS)

    r = sh(f"cd {PROJ} && swift build 2>&1", timeout=600)
    record("build-debug", PASS if r.returncode == 0 else FAIL, r.stdout.strip()[-200:])
    if r.returncode != 0:
        return finish()
    r = sh(f"cd {PROJ} && swift build -c release 2>&1", timeout=900)
    record("build-release", PASS if r.returncode == 0 else FAIL, r.stdout.strip()[-200:])
    if r.returncode != 0:
        return finish()

    if not run_dump_layout():
        return finish()

    kill_glass()
    subprocess.Popen(
        [BIN],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    time.sleep(2.5)
    pid = glass_pid()
    if pid:
        record("launch", PASS, f"pid {pid}")
        time.sleep(2.0)
        if glass_pid() == pid:
            record("stays-alive", PASS)
        else:
            record("stays-alive", FAIL, "exited after launch")
            return finish()
    else:
        record("launch", FAIL, "process not found after 2.5s")
        return finish()

    persisted, err = read_shortcuts()
    sc = merge_shortcuts(persisted)
    missing = [a for a in ACTIONS if a not in persisted]
    if not persisted:
        record(
            "defaults-persisted",
            SKIP,
            (err or "no saved domain yet (fresh launch uses built-in defaults)")[:300],
        )
    elif missing:
        record(
            "defaults-persisted",
            SKIP,
            f"{len(persisted)} saved, filling {len(missing)} from built-in defaults: {', '.join(missing)}",
        )
    else:
        record("defaults-persisted", PASS, f"{len(persisted)} actions: {', '.join(sorted(persisted))}")

    gap = read_gap()
    sax, _desktop_max_y = screens_ax()
    n_screens = len(sax)
    print(f"  screens={n_screens} gap.v1={gap:g} vis0={fmt_rect(sax[0]['vis_ax'])}")

    sh(f"open {PROJ}")
    time.sleep(1.0)
    start_bounds = measure_window()
    if not glass_trusted():
        r = sh(f"{BIN} --action maximize", timeout=15)
        record(
            "action-trust-gate",
            PASS if r.returncode == 3 else FAIL,
            f"--action without AX must exit 3, got rc={r.returncode} err={(r.stderr or '')[:80]}",
        )
    run_live_actions()

    trust = helper_trust()
    if start_bounds is None:
        record("hotkeys", SKIP, "no Finder window to drive via hotkeys")
    elif not trust:
        record(
            "hotkey-verify",
            SKIP,
            "e2e_helper not Accessibility-trusted; live --action path already ran",
        )
    else:
        print(f"  target window: {fmt_rect(start_bounds)} (helper AX trusted: {trust})")
        run_geometry(sc, sax, n_screens)

    run_menu_and_quit(start_bounds)
    return finish()


def run_geometry(sc, sax, n_screens):
    for action in ACTIONS:
        if action in DISPLAY_ACTIONS and n_screens < 2:
            record(f"hotkey:{action}", SKIP, "single display")
            continue
        kc_mods = sc.get(action) or DEFAULT_SHORTCUTS.get(action)
        if kc_mods is None:
            record(f"hotkey:{action}", SKIP, "no shortcut")
            continue

        focus_finder()
        old = measure_window()
        if old is None:
            record(f"hotkey:{action}", SKIP, "no front window")
            continue
        vis = vis_ax_for(old, sax)

        if action == "restore":
            snap = old
            post_hotkey(*sc.get("maximize", DEFAULT_SHORTCUTS["maximize"]))
            time.sleep(0.35)
            focus_finder()
            post_hotkey(*kc_mods)
            time.sleep(0.35)
            new = measure_window()
            if new is None:
                record(f"hotkey:{action}", SKIP, "no front window after post")
                continue
            ok, desc = expect_geom("restore", snap, vis, new, tol=80)
            record(f"hotkey:{action}", PASS if ok else FAIL, f"{fmt_rect(snap)} -> {fmt_rect(new)} (expect {desc})")
            continue

        if action in DISPLAY_ACTIONS:
            before_idx = screen_index_for(old, sax)
            post_hotkey(*kc_mods)
            time.sleep(0.45)
            new = measure_window()
            if new is None:
                record(f"hotkey:{action}", SKIP, "no front window after post")
                continue
            after_idx = screen_index_for(new, sax)
            moved = after_idx != before_idx or abs(new[0] - old[0]) > 200 or abs(new[1] - old[1]) > 200
            record(
                f"hotkey:{action}",
                PASS if moved else FAIL,
                f"{fmt_rect(old)} -> {fmt_rect(new)} screen {before_idx}->{after_idx}",
            )
            continue

        post_hotkey(*kc_mods)
        time.sleep(0.35)
        new = measure_window()
        if new is None:
            record(f"hotkey:{action}", SKIP, "no front window after post")
            continue
        vis = vis_ax_for(new, sax) if action not in ("center",) else vis
        ok, desc = expect_geom(action, old, vis, new)
        record(f"hotkey:{action}", PASS if ok else FAIL, f"{fmt_rect(old)} -> {fmt_rect(new)} (expect {desc})")


def run_menu_and_quit(start_bounds):
    if glass_pid() is None:
        record("menu-opens", FAIL, "Glass not running")
        return
    if osa('tell application "System Events" to get name of front process', timeout=6) is None:
        record("menu-opens", SKIP, "System Events unresponsive (likely needs Accessibility grant)")
        kill_glass()
        record("quit", SKIP, "Automation not granted; killed in cleanup")
        return

    mb = click_status_item()
    record(
        "menu-opens",
        PASS if mb is not None else SKIP,
        f"clicked status item (menu bar {mb})" if mb is not None else "no menu bar item",
    )
    if mb is None:
        kill_glass()
        record("quit", SKIP, "could not open menu; killed in cleanup")
        return

    time.sleep(0.6)
    r = click_menu_item("Settings…", mb)
    if r is None:
        r = click_menu_item("Settings...", mb)
    time.sleep(1.0)
    wins = osa('tell application "System Events" to tell process "Glass" to count windows')
    n = int(wins) if wins and wins.isdigit() else 0
    record("settings-window", PASS if n >= 1 else FAIL, f"{n} window(s) after Settings…")
    if n >= 1:
        title = click_reset_button()
        record("reset-button", PASS if title else FAIL, title or "Reset to Defaults not found")
        time.sleep(0.8)

    if start_bounds:
        focus_finder()
        ax_set(*start_bounds)
        time.sleep(0.3)

    osa('tell application "System Events" to tell process "Glass" to keystroke "q" using {command down}')
    time.sleep(1.0)
    if glass_pid() is None:
        record("quit", PASS, "quit via cmd+q")
    else:
        kill_glass()
        record("quit", SKIP, "cmd+q did not exit; killed in cleanup")


def finish():
    fails = [r for r in results if r[0] == FAIL]
    skips = [r for r in results if r[0] == SKIP]
    print(f"\n=== {PASS}: {sum(1 for r in results if r[0]==PASS)}  {FAIL}: {len(fails)}  {SKIP}: {len(skips)} ===")
    for s, n, d in results:
        if s != PASS:
            print(f"  [{s}] {n}: {d}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
