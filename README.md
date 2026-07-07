# obs-capture-restarter

An OBS Studio Lua script for macOS that automatically restarts frozen screen
and audio captures — **event-driven, with no polling and no stutter in your
recordings.**

## The problem

On macOS, OBS's **Screen Capture** and **Audio Capture** sources freeze when
the ScreenCaptureKit stream behind them dies: waking from sleep
([obs-studio #8928](https://github.com/obsproject/obs-studio/issues/8928),
closed *not planned*), unplugging a display, or random mid-session stops. The
video sticks on the last frame, the audio goes silent, and nothing recovers
on its own — you have to press the **Restart Capture** button in the source
properties or restart OBS. Miss it once and you've recorded an hour of frozen
screen.

## How this script works

When a capture dies, OBS *knows*: it sets an internal `capture_failed` flag,
enables the Restart Capture button, and — the key detail — **emits the
source's `update_properties` signal** (see
[`mac-sck-common.m`](https://github.com/obsproject/obs-studio/blob/master/plugins/mac-capture/mac-sck-common.m)).

This script listens for that signal and presses the button for you:

1. **Failure signal** fires the moment a capture dies — no polling.
2. **Display-ready gate:** restarting immediately after wake binds the new
   ScreenCaptureKit stream to a display that isn't lit yet — the stream
   reports healthy but delivers only black frames, with no error and
   therefore no retry. WindowServer brings displays back 1–4 s *after*
   processes resume. So the script asks CoreGraphics directly (via LuaJIT
   FFI: `CGDisplayIsActive` / `CGDisplayIsAsleep`) and waits until the main
   display is genuinely awake, plus a 2 s settle, before pressing the button.
3. **Restart Capture is pressed** programmatically
   (`obs_property_enabled` → `obs_property_button_clicked`) — the same thing
   as your click in the properties dialog, for video and audio captures.

Typical recovery: your capture is live again ~2–3 seconds after the screen
lights up, without OBS restarting and without you touching anything.

### Why event-driven matters

Existing tools poll. WebSocket watchdogs screenshot the source every second
and restart it when frames stop changing — an idle screen looks exactly like
a frozen capture, so they misfire. Polling Lua scripts (like
[tcrinky/obs-mac-capture-restarter](https://github.com/tcrinky/obs-mac-capture-restarter),
which inspired this one — thanks!) check the button state on a timer, but
building a capture source's properties forces ScreenCaptureKit to
re-enumerate shareable content, causing a visible **50–100 ms stutter in
recordings on every check**
([issue](https://github.com/tcrinky/obs-mac-capture-restarter/issues/3)).

This script does neither: while your captures are healthy, its only activity
is a once-per-second boolean check. The expensive work happens exactly once —
at the moment a capture actually fails.

## Install

1. Download [`obs-capture-restarter.lua`](obs-capture-restarter.lua) (keep it
   somewhere permanent — OBS references the file by path).
2. In OBS: **Tools → Scripts → +** → select the file.
3. Check the **Script Log**: you should see
   `Capture restarter active (event-driven, no polling)` and one
   `Watching capture source: …` line per capture source.

Requires OBS 28+ on macOS (Lua scripting and the ScreenCaptureKit capture
sources). No other dependencies, no WebSocket setup.

## Test it

With OBS open, put your Mac to sleep and wake it. Within a few seconds of the
screen lighting up, the Script Log shows:

```
Restarted frozen capture: <your source name>
```

and your capture is live again.

## Troubleshooting

- **Capture comes back black after wake:** the display-ready gate should
  prevent this, but if it ever happens, raise **"Settle time after display
  wakes"** in the script's settings (Tools → Scripts → select the script),
  e.g. to 5.
- **Nothing in the Script Log after wake:** OBS never flagged the capture as
  failed. This is rare but real — with *virtual displays* (DisplayLink,
  BetterDisplay, Sidecar), ScreenCaptureKit can silently capture the wrong
  or empty framebuffer without reporting any error
  ([Apple forums](https://developer.apple.com/forums/thread/786829)). No
  tool can auto-detect that case — including OBS itself.
- The script only fixes sources OBS marks as failed; it never touches a
  healthy capture and never interrupts a recording.

## License

[MIT](LICENSE) — inspired by
[tcrinky/obs-mac-capture-restarter](https://github.com/tcrinky/obs-mac-capture-restarter).
