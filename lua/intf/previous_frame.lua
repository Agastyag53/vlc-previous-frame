--[[
 Previous Frame hotkey for VLC 3.x

 VLC ships a "Next frame" hotkey (E) but no "Previous frame". This Lua
 interface script adds one: press Q (configurable) to step back exactly
 one frame. Like E, pressing it while playing pauses the video first.

 Install: copy this file into VLC's "lua/intf" folder and enable it as an
 extra interface. See README.md for step-by-step instructions.

 Options (all optional), set via Tools > Preferences > All > Interface >
 Main interfaces > Lua > "Lua interface configuration", e.g.:
     previous_frame={key="w"}
     previous_frame={key="Alt+w", fps=23.976}

   key  Hotkey in VLC's own syntax: "q", "w", "Shift+q", "Alt+Left"...
        Several keys can be separated with a tab character.
   fps  Force the frame rate when VLC can't detect it correctly.

 How it works
 ------------
 VLC 3 offers no backwards decoding, so stepping back means seeking. A seek
 while paused shows the first frame whose timestamp is at or after the
 target, so seeking to the middle of the gap before frame N shows exactly
 frame N. The hard part is knowing which frame is on screen: the "time"
 variable VLC exposes to scripts is only refreshed every 250 ms while
 playing, is not touched by frame stepping, and is skewed after a seek
 while paused. So this script keeps track of the frame number itself:

   * when playback gets paused, it extrapolates from the last refresh of
     "time" to the moment of the pause;
   * after each of its own seeks it knows the exact frame on screen;
   * it counts "Next frame" key presses so E and Q can be mixed freely;
   * it notices seeks made while paused (the input statistics change) and
     falls back to VLC's "time" variable in that case.
--]]

local DEFAULT_KEY = "q"

local POLL_US = 10000         -- how often keys and player state are checked
local SETTLE_US = 500000      -- how long our own actions may disturb the stats
local AFTER_NEXT_US = 50000   -- let VLC handle its "Next frame" before seeking
local FALLBACK_FPS = 25

local PLAYING_S, PAUSE_S = 2, 3

local MODIFIERS = {
    ctrl    = 0x04000000,
    alt     = 0x01000000,
    shift   = 0x02000000,
    meta    = 0x08000000,
    command = 0x10000000,
}

-- Key names understood by VLC (src/misc/actions.c, include/vlc_actions.h)
local NAMED_KEYS = {
    ["Backspace"] = 0x08, ["Tab"] = 0x09, ["Enter"] = 0x0D, ["Esc"] = 0x1B,
    ["Space"] = 0x20,
    ["Left"] = 0x00210000, ["Right"] = 0x00220000,
    ["Up"] = 0x00230000, ["Down"] = 0x00240000,
    ["F1"] = 0x00270000, ["F2"] = 0x00280000, ["F3"] = 0x00290000,
    ["F4"] = 0x002A0000, ["F5"] = 0x002B0000, ["F6"] = 0x002C0000,
    ["F7"] = 0x002D0000, ["F8"] = 0x002E0000, ["F9"] = 0x002F0000,
    ["F10"] = 0x00300000, ["F11"] = 0x00310000, ["F12"] = 0x00320000,
    ["Home"] = 0x00330000, ["End"] = 0x00340000,
    ["Insert"] = 0x00350000, ["Delete"] = 0x00360000,
    ["Menu"] = 0x00370000,
    ["Page Up"] = 0x00390000, ["Page Down"] = 0x003A0000,
    ["Print"] = 0x003B0000, ["Pause"] = 0x003D0000,
    ["Media Prev Frame"] = 0x00560000, ["Media Next Frame"] = 0x00570000,
}

local cfg = type(config) == "table" and config or {}

local function log(fmt, ...)
    vlc.msg.dbg("[previous_frame] " .. string.format(fmt, ...))
end

-- Code point of the first UTF-8 character of s (Lua 5.2 has no utf8 lib)
local function first_codepoint(s)
    local c = s:byte(1)
    if not c then return nil end
    if c < 0x80 then return c end
    local len = c >= 0xF0 and 4 or c >= 0xE0 and 3 or 2
    local cp = c % (2 ^ (7 - len))
    for i = 2, len do
        local b = s:byte(i)
        if not b then return nil end
        cp = cp * 64 + b % 64
    end
    return cp
end

-- Same rules as vlc_str2keycode(): modifiers joined with "+" or "-"
local function parse_key(name)
    local mods, seen = 0, {}
    while true do
        local sep = name:find("[-+]")
        if not sep or sep == 1 then break end
        local mod = name:sub(1, sep - 1):lower()
        if MODIFIERS[mod] and not seen[mod] then
            mods = mods + MODIFIERS[mod]
            seen[mod] = true
        end
        name = name:sub(sep + 1)
    end
    local code = NAMED_KEYS[name] or first_codepoint(name)
    if not code or code == 0 then return nil end
    return mods + code
end

-- A tab-separated list of keys, as stored in VLC's key-* options
local function parse_key_list(list)
    local codes = {}
    for name in tostring(list or ""):gmatch("[^\t]+") do
        local code = parse_key(name)
        if code then codes[code] = true end
    end
    return codes
end

local prev_keys = parse_key_list(cfg.key or DEFAULT_KEY)
local next_keys = parse_key_list(vlc.config.get("key-frame-next"))

local function to_number(v)
    return tonumber((tostring(v):gsub(",", "."):match("%d+%.?%d*")))
end

-- Frame rate of the current item, from the "Codec" info panel. The labels
-- are translated, so when the English one is missing take the only plain
-- number found in a stream that has a "WxH" resolution.
local function detect_fps(item)
    local fallback
    for _, fields in pairs(item:info() or {}) do
        if type(fields) == "table" then
            local is_video, candidates = false, {}
            for k, v in pairs(fields) do
                v = tostring(v)
                if k == "Frame rate" then
                    local fps = to_number(v)
                    if fps and fps > 0 then return fps end
                end
                if v:match("^%d+x%d+$") then is_video = true end
                if v:match("^%d+[.,]?%d*$") then candidates[#candidates + 1] = v end
            end
            if is_video and #candidates == 1 then
                local fps = to_number(candidates[1])
                if fps and fps > 0 and fps <= 1000 then fallback = fps end
            end
        end
    end
    return fallback
end

-- Per-media state
local uri            -- current media, to notice when it changes
local frame_us       -- duration of one frame
local frame          -- index of the frame on screen while paused, if known
local seeked         -- whether our last action was a seek
local seek_due       -- when to seek to `frame` (see step_forward)
local stats_sig      -- input stats while paused, to notice outside seeks
local settle_until   -- our own actions may still change the stats until then
local time_seen      -- last value of the "time" variable while playing
local time_seen_at   -- when that value appeared
local resumed_from   -- known timestamp playback resumed from, if any
local resumed_at     -- when that happened

local last_state, last_poll

local function reset()
    uri, frame_us, frame, seeked, seek_due = nil, nil, nil, false, nil
    stats_sig, settle_until = nil, 0
    time_seen, time_seen_at, resumed_from, resumed_at = nil, nil, nil, nil
end

local function frame_duration(item)
    if not frame_us then
        local fps = tonumber(cfg.fps) or detect_fps(item)
        if not fps then
            log("frame rate unknown, assuming %d fps", FALLBACK_FPS)
            return 1000000 / FALLBACK_FPS
        end
        frame_us = 1000000 / fps
        log("frame rate %.3f fps", fps)
    end
    return frame_us
end

-- Best guess of the timestamp on screen when playback paused at `at`
local function estimate_time(input, at)
    local t = vlc.var.get(input, "time")
    local rate = vlc.var.get(input, "rate")
    if time_seen_at and t == time_seen then
        return t + (at - time_seen_at) * rate
    end
    -- After a seek VLC only refreshes "time" once it has buffered again
    if resumed_from then
        return resumed_from + (at - resumed_at) * rate
    end
    return t
end

local function signature(input, item)
    local s = item:stats() or {}
    return table.concat({ vlc.var.get(input, "time"),
                          tostring(s.demux_read_bytes),
                          tostring(s.decoded_video) }, "|")
end

local function show_frame(input, item, n, now)
    frame = math.max(0, n)
    -- Middle of the gap before the wanted frame: VLC shows the first frame
    -- at or after the target, and small timestamp offsets don't matter.
    local target = math.max(0, math.floor((frame - 0.5) * frame_duration(item)))
    log("show frame %d (seek to %d us)", frame, target)
    vlc.var.set(input, "time", target)
    seeked, seek_due = true, nil
    settle_until = now + SETTLE_US
end

local function step_back(input, item, state, now)
    if state == PLAYING_S then
        vlc.var.set(input, "state", PAUSE_S)
        frame = math.floor(estimate_time(input, now) / frame_duration(item))
    elseif state ~= PAUSE_S then
        return state
    elseif not frame then
        local t = vlc.var.get(input, "time")
        frame = math.floor(t / frame_duration(item) + 0.5)
        log("position unknown, using time %d us", t)
    end
    if frame > 0 then
        show_frame(input, item, frame - 1, now)
    end
    return PAUSE_S
end

local function step_forward(input, item, now)
    if seeked then
        -- VLC ignores the first "Next frame" after a seek while paused (it
        -- shows the same frame again), so do the step ourselves. Not right
        -- away though: a seek that closely follows "Next frame" can leave
        -- the video output stuck.
        frame = frame + 1
        seek_due = now + AFTER_NEXT_US
        settle_until = now + SETTLE_US
    else
        frame = frame + 1
        settle_until = now + SETTLE_US
    end
end

local function poll()
    local now = vlc.misc.mdate()
    local libvlc = vlc.object.libvlc()

    local key = vlc.var.get(libvlc, "key-pressed")
    if key ~= 0 then
        -- Clear it so that pressing the same key again is noticed. VLC's
        -- own hotkey handling has already run; 0 maps to no action.
        vlc.var.set(libvlc, "key-pressed", 0)
    end

    local input = vlc.object.input()
    local item = input and vlc.input.item()
    if not item then
        reset()
        last_state = nil
        return
    end
    if item:uri() ~= uri then
        reset()
        uri = item:uri()
    end

    local state = vlc.var.get(input, "state")

    if state == PLAYING_S then
        local t = vlc.var.get(input, "time")
        if last_state ~= PLAYING_S then
            time_seen, time_seen_at = t, nil
            resumed_from = frame and frame * frame_duration(item)
            resumed_at = now
        elseif t ~= time_seen then
            -- The change happened somewhere since the previous poll
            time_seen, time_seen_at = t, (now + last_poll) / 2
        end
        frame, seeked, seek_due, stats_sig = nil, false, nil, nil
    elseif state == PAUSE_S and last_state == PLAYING_S then
        local paused_at = (now + last_poll) / 2
        local t = estimate_time(input, paused_at)
        frame = math.floor(t / frame_duration(item))
        settle_until = now + SETTLE_US
        log("paused on frame %d (estimated %d us)", frame, t)
    end

    if next_keys[key] and frame and last_state == PAUSE_S then
        step_forward(input, item, now)
    end

    if prev_keys[key] then
        state = step_back(input, item, state, now)
    end

    if seek_due and now >= seek_due then
        show_frame(input, item, frame, now)
    end

    -- A seek made while paused (seek bar, arrow keys...) changes the input
    -- statistics. Ours do too, so only look once they have settled.
    if state == PAUSE_S and frame then
        local sig = signature(input, item)
        if now < settle_until or not stats_sig then
            stats_sig = sig
        elseif sig ~= stats_sig then
            log("position changed outside of this script")
            frame, seeked, seek_due, stats_sig = nil, false, nil, nil
        end
    end

    last_state = state
end

local function run()
    last_poll = vlc.misc.mdate()
    while true do
        local ok, err = pcall(poll)
        if not ok then
            vlc.msg.err("[previous_frame] " .. tostring(err))
            reset()
        end
        last_poll = vlc.misc.mdate()
        -- Raises "Interrupted." when VLC shuts the interface down
        vlc.misc.mwait(last_poll + POLL_US)
    end
end

log("loaded")
local ok, err = pcall(run)
if not ok and not tostring(err):find("Interrupted") then
    error(err, 0)
end
