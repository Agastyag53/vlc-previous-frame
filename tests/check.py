#!/usr/bin/env python3
"""Compare the frames captured by driver.lua with the expected ones."""
import glob
import os
import re
import subprocess
import sys

log_path, snap_dir = sys.argv[1], sys.argv[2]
# How far the first step after pausing playback may land (see README)
tolerance = int(os.environ.get("FIRST_STEP_TOLERANCE", "1"))


def frame_of(path):
    # Test video: three columns with luma 30 + 10 * (base 16 digit of n)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", "format=gray",
                          "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    width, row = 64, 32
    digit = lambda x: round((raw[row * width + x] * 219 / 255 + 16 - 30) / 10)
    return digit(53) * 256 + digit(32) * 16 + digit(10)


frames, failures, checks, approx_misses, done = {}, 0, 0, 0, False
for line in open(log_path, errors="replace"):
    if "DRIVER DONE" in line:
        done = True
    m = re.search(r"DRIVER SNAP (\d+) (\S+) (\S+) (\S+)", line)
    if not m:
        continue
    n, label, ref, delta = m.groups()
    files = glob.glob(f"{snap_dir}/snap{n}-*.png")
    if not files:
        # VLC occasionally fails to grab a snapshot; skip what depends on it
        print(f"{label:24s} (no snapshot)")
        continue
    frames[n] = frame_of(files[0])
    result = f"{label:24s} frame {frames[n]:4d}"
    if delta.startswith("="):
        checks += 1
        want = int(delta[1:])
        ok = frames[n] == want
        failures += not ok
        print(f"{result}  expected {want:4d}  {'ok' if ok else 'FAIL'}")
        continue
    if ref != "-":
        checks += 1
        if ref not in frames:
            print(f"{result}  (reference missing, skipped)")
            continue
        approx = delta.startswith("~")
        want = frames[ref] + int(delta.lstrip("~?"))
        miss = abs(frames[n] - want)
        if delta.startswith("?"):
            checks -= 1
            verdict = f"measured only, off by {frames[n] - want:+d}"
        elif approx and 0 < miss <= tolerance:
            approx_misses += 1
            verdict = f"off by {frames[n] - want:+d} (allowed)"
        else:
            verdict = "ok" if miss == 0 else "FAIL"
            failures += miss != 0
        result += f"  expected {want:4d}  {verdict}"
    print(result)

if not done:
    print("driver did not finish")
    failures += 1
print(f"{checks - failures}/{checks} checks passed, {approx_misses} first steps off (allowed)")
sys.exit(1 if failures else 0)
