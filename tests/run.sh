#!/bin/sh
# End-to-end test against a real VLC 3 (Linux, needs cvlc, ffmpeg, python3).
# Usage: tests/run.sh [seed]
# Environment: FPS (frame rate of the test video, default 25),
#   LUA_CONFIG + PREV_KEY_CODE to test another hotkey, e.g.
#   LUA_CONFIG='previous_frame={key="w"}' PREV_KEY_CODE=119
#   FIRST_STEP_TOLERANCE (frames, default 1; use 2 above 25 fps),
#   KEEP_DIR to keep the video, log and snapshots there,
#   VFR=1 for a variable frame rate video
set -e
here=$(cd "$(dirname "$0")" && pwd)
if [ -n "$KEEP_DIR" ]; then
    work=$KEEP_DIR; mkdir -p "$work"
else
    work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fi

# Uneven frame timing (like phone and screen recordings) with VFR=1
vfr=
[ -n "$VFR" ] && vfr=",setpts='(N+0.4*sin(1.7*N))/FRAME_RATE/TB'"

# 30 s at 25 fps, frame number encoded (base 16) in the brightness of three
# columns,
# B-frames and a 4 s GOP so that stepping back has to decode from a keyframe.
ffmpeg -v error -f lavfi \
    -i "nullsrc=s=64x64:r=${FPS:-25}:d=30,geq=lum='30+10*if(lt(X,21),mod(N,16),if(lt(X,43),mod(floor(N/16),16),floor(N/256)))':cb=128:cr=128,format=yuv420p$vfr" \
    -f lavfi -i "sine=f=440:d=30" \
    -c:v libx264 -qp 0 -g 100 -bf 2 -fps_mode passthrough -c:a aac -shortest "$work/test.mp4"

mkdir -p "$work/lua/intf" "$work/snaps"
cp "$here/../lua/intf/previous_frame.lua" "$here/driver.lua" "$work/lua/intf/"

SEED=${1:-1} PREV_KEY_CODE=${PREV_KEY_CODE:-113} VLC_DATA_PATH="$work" timeout 300 cvlc -vv --no-video-title-show \
    --lua-config "${LUA_CONFIG:-}" \
    --extraintf "luaintf{intf=previous_frame}:luaintf{intf=driver}" \
    --aout adummy -V vdummy \
    --snapshot-path="$work/snaps" --snapshot-sequential --snapshot-format=png \
    "$work/test.mp4" > "$work/log.txt" 2>&1 || true

python3 "$here/check.py" "$work/log.txt" "$work/snaps"
