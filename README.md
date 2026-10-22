# Previous Frame hotkey for VLC

VLC has a **Next frame** hotkey (`E`) but no **Previous frame**. This add-on
adds one: press **`Q`** to step back one frame. You can change the key to
`W` or anything else.

- Pressing it while the video plays pauses it and steps back, like `E` pauses
  and steps forward.
- You can mix `E` and `Q` freely to go back and forth frame by frame.
- It works with any video VLC can seek in. The frame rate is detected
  automatically.

Requires **VLC 3.0.x** (the current stable version) on Windows, macOS or
Linux. VLC 4 changed the scripting interface and isn't supported.

## Install

1. Download [`lua/intf/previous_frame.lua`](lua/intf/previous_frame.lua).
2. Copy it into VLC's `lua/intf` folder for your user. Create any folders
   that are missing:

   | System  | Folder |
   |---------|--------|
   | Windows | `%APPDATA%\vlc\lua\intf\` (paste that into the Explorer address bar) |
   | macOS   | `~/Library/Application Support/org.videolan.vlc/lua/intf/` |
   | Linux   | `~/.local/share/vlc/lua/intf/` |
   | Linux (Snap) | `~/snap/vlc/current/.local/share/vlc/lua/intf/` |
   | Linux (Flatpak) | `~/.var/app/org.videolan.VLC/data/vlc/lua/intf/` |

3. Turn it on in VLC:
   1. Open **Tools › Preferences** (macOS: **VLC › Settings**).
   2. Bottom left, under **Show settings**, select **All**.
   3. Go to **Interface › Main interfaces**. In the text field under
      **Extra interface modules**, type `luaintf`.

      Don't use the **Lua interpreter** checkbox: it writes `lua` into the
      field, which makes VLC open its command-line console instead of
      loading this add-on. Once `luaintf` is typed in, it doesn't matter
      whether that checkbox looks ticked or not.
   4. Expand **Main interfaces**, select **Lua**, and type `previous_frame`
      in **Lua interface**.
   5. Click **Save**, then quit and restart VLC.

To try it once without changing your settings, start VLC from a terminal
instead:

```sh
vlc --extraintf=luaintf --lua-intf=previous_frame video.mp4
```

## Use

| Key | Action |
|-----|--------|
| `Space` | Play / pause |
| `E` | Next frame (built into VLC) |
| `Q` | Previous frame (this add-on) |

Keyboard focus has to be on the VLC window (or the video), as with VLC's own
hotkeys.

## Use a different key (e.g. `W`)

In **Tools › Preferences › All › Interface › Main interfaces › Lua**, set
**Lua interface configuration** to:

```lua
previous_frame={key="w"}
```

Save and restart VLC. Keys use VLC's own spelling: `"w"`, `"Shift+q"`,
`"Alt+w"`, `"Left"`, `"Page Up"`, `"F5"`… Letters are case sensitive, so
use lowercase.

If you prefer, edit the line `local DEFAULT_KEY = "q"` at the top of the
script instead.

> [!NOTE]
> VLC binds `W` to **Toggle wallpaper mode** by default. That only does
> anything with a few video outputs on Windows, but if you pick `W`, clear
> that hotkey in **Tools › Preferences › Hotkeys** to be safe. `Q` isn't
> used by VLC.

If VLC reports the wrong frame rate for a video (the script then steps by the
wrong amount), you can force it:

```lua
previous_frame={key="q", fps=23.976}
```

## How accurate is it?

Every step is exactly one frame, with one exception: **the first `Q` right
after you pause playback** (or `Q` pressed while playing) can land one frame
off, occasionally two at high frame rates. After that, each press of `Q` or
`E` moves exactly one frame.

This happens because VLC 3 doesn't let scripts see exactly which frame is on
screen when you pause. The time it reports can be off by a few tens of
milliseconds, so the script has to estimate. Once the script has made its own
first step, it knows the exact frame and keeps track from there.

Moving the position while paused (clicking or dragging the seek bar, or using
the jump hotkeys) is detected, and the next `Q` steps back from the new
position.

## How it works

VLC 3 can't decode backwards, so the script steps back by seeking. A seek
while paused shows the first frame at or after the target time, so the script
seeks to just before the frame it wants. It runs as a small Lua "interface"
in the background and checks every 10 ms which key was pressed last. The
check is cheap: about 1% of one CPU core.

Two VLC quirks are worked around:

- After a seek while paused, VLC ignores the next **Next frame** and shows the
  same frame again. When you press `E` right after a `Q`, the script makes
  that step itself.
- The playback time VLC reports to scripts doesn't follow frame stepping and
  is unreliable right after a seek. The script counts frames itself instead.

You can see what it does in **Tools › Messages** with verbosity set to
**2 (debug)**. Its lines start with `[previous_frame]`.

## Troubleshooting

- **A black console window opens with VLC** ("Command Line Interface
  initialized") **and Q does nothing.** The **Extra interface modules** field
  says `lua` instead of `luaintf`; ticking the **Lua interpreter** checkbox
  does that. Replace `lua` with `luaintf`, save and restart VLC.
- **Nothing happens when I press Q.** Check that **Extra interface modules**
  says `luaintf` (not `lua`) and that **Lua interface** says exactly
  `previous_frame`, then restart VLC.
  In **Tools › Messages** (verbosity 2), look for
  `[previous_frame] loaded`. If it's missing, the file is in the wrong
  folder.
- **It steps by more than one frame.** VLC probably reports the wrong frame
  rate. Set `fps` as shown above.
- **I already use another script in Lua interface.** Leave that one there
  and add this one under **Interface › Main interfaces › Extra interface
  modules** as `luaintf{intf=previous_frame}` instead. VLC's web and telnet
  interfaces are separate modules and aren't affected either way.

## Tests

`tests/run.sh` runs the script in a real VLC 3 on Linux (needs `cvlc`,
`ffmpeg` and `python3`). It generates a video whose frames encode their own
frame numbers, simulates key presses and checks the frame shown after each
press against the expected one.

```sh
tests/run.sh           # 25 fps
FPS=30000/1001 FIRST_STEP_TOLERANCE=2 tests/run.sh
LUA_CONFIG='previous_frame={key="w"}' PREV_KEY_CODE=119 tests/run.sh
```
