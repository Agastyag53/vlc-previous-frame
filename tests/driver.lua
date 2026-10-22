--[[
 Test driver for previous_frame.lua, run as a second Lua interface.
 Simulates key presses and takes snapshots; check.py reads the frame
 number encoded in each snapshot and compares it with the expectation
 logged here as "SNAP <n> <label> <reference snap> <expected delta>".
 A delta prefixed with "~" may be off by one frame (first step after
 pausing playback, see README).
--]]

local KEY_SPACE, KEY_E = 32, 101
-- Code of the key previous_frame.lua is configured with (default: q)
local KEY_Q = tonumber(os.getenv("PREV_KEY_CODE") or "113")

local function sleep(ms) vlc.misc.mwait(vlc.misc.mdate() + ms * 1000) end
local function log(...)
    local t = {}
    for i, v in ipairs({...}) do t[i] = tostring(v) end
    vlc.msg.err("DRIVER " .. table.concat(t, " "))
end

local input
repeat sleep(50); input = vlc.object.input() until input and vlc.var.get(input, "state") == 2
local vout
repeat sleep(50); vout = vlc.object.vout() until vout
local libvlc = vlc.object.libvlc()

local function press(key) vlc.var.set(libvlc, "key-pressed", key) end

-- Name each snapshot after its number, so that a failed one can't shift
-- the numbering of the following ones
vlc.var.create(vout, "snapshot-prefix", "")
local n = 0
-- Snapshot; expect frame(ref) + delta, or frame "=N" with ref nil
local function snap(label, ref, delta)
    sleep(400)
    if delta and not ref then ref = "abs" end
    n = n + 1
    vlc.var.set(vout, "snapshot-prefix", "snap" .. n .. "-")
    vlc.var.trigger_callback(vout, "video-snapshot")
    sleep(250)
    log("SNAP", n, label, ref or "-", delta or "-")
    return n
end

math.randomseed(tonumber(os.getenv("SEED") or "1"))

-- Pause with Space at random moments, step back twice, then forward with E
for i = 1, 8 do
    vlc.var.set(input, "time", math.random(0, 20000000))
    sleep(600 + math.random(0, 600))
    press(KEY_SPACE)
    local s = snap("pause" .. i)
    press(KEY_Q)
    s = snap("back", s, "~-1")
    press(KEY_Q)
    s = snap("back", s, -1)
    press(KEY_E)
    s = snap("E-after-Q", s, 1)
    press(KEY_E)
    s = snap("E", s, 1)
    press(KEY_Q)
    s = snap("back", s, -1)
    press(KEY_SPACE)
end

-- Native E steps after pausing, then Q
sleep(800)
press(KEY_SPACE)
local s = snap("pause")
for i = 1, 3 do press(KEY_E); sleep(150) end
s = snap("E-x3", s, 3)
press(KEY_Q)
s = snap("back", s, "~-1")
press(KEY_Q); sleep(100); press(KEY_Q); sleep(100); press(KEY_Q)
s = snap("back-x3", s, -3)

-- Key repeat
for i = 1, 6 do press(KEY_Q); sleep(40) end
s = snap("back-x6-fast", s, -6)
for i = 1, 4 do press(KEY_E); sleep(40) end
s = snap("E-x4-fast", s, 4)

-- Short replay after stepping (VLC refreshes "time" late after a seek)
press(KEY_SPACE)
sleep(500)
press(KEY_SPACE)
s = snap("short-replay")
press(KEY_Q)
s = snap("back", s, "~-1")

-- Q while playing pauses and steps back
press(KEY_SPACE)
sleep(1000)
press(KEY_Q)
s = snap("Q-while-playing")
press(KEY_Q)
s = snap("back", s, -1)

-- Moving while paused (seek bar click, dragging, jump hotkeys), then Q.
-- VLC doesn't report the new position precisely, so the first step is only
-- measured ("?"); the following ones must be exact.
local moves = {
    { "seek-bar-click", function() vlc.var.set(input, "position", 0.5) end },
    { "seek-bar-drag", function()
        for p = 30, 36 do vlc.var.set(input, "position", p / 100); sleep(60) end
    end },
    { "jump-hotkey", function() vlc.var.set(input, "time-offset", 3000000) end },
    { "jump-hotkey-back", function() vlc.var.set(input, "time-offset", -10000000) end },
}
for _, move in ipairs(moves) do
    sleep(1000)
    move[2]()
    s = snap(move[1])
    press(KEY_Q)
    s = snap("back", s, "?-1")
    press(KEY_Q)
    s = snap("back", s, -1)
end

-- Stepping back stops at the very first frame
sleep(1000)
vlc.var.set(input, "time", 0)
sleep(700)
press(KEY_SPACE)
sleep(300)
press(KEY_SPACE)
s = snap("near-start")
for i = 1, 20 do press(KEY_Q); sleep(60) end
s = snap("first-frame", nil, "=0")
press(KEY_E)
s = snap("E", s, 1)

log("DONE")
vlc.misc.quit()
