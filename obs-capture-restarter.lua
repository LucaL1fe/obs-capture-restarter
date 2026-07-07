--[[
obs-capture-restarter.lua — event-driven auto-restart for frozen macOS captures.

When a ScreenCaptureKit stream dies (wake from sleep, display unplugged,
random SCK stop), OBS sets an internal capture_failed flag, enables the
"Restart Capture" button in the source properties, and emits the source's
"update_properties" signal (mac-sck-common.m). This script listens for that
signal and presses the button programmatically.

Unlike polling scripts (e.g. tcrinky/obs-mac-capture-restarter, which
inspired this), it does NO periodic work: building a capture source's
properties forces ScreenCaptureKit to re-enumerate shareable content, which
causes a visible 50-100 ms stutter in recordings when done on a timer.
Here that cost is only paid at the moment a capture actually fails.

Install: OBS -> Tools -> Scripts -> + -> select this file.  macOS only.
]]

local obs = obslua

-- Source types whose properties carry a "reactivate_capture" button
-- (covers display/window/application video capture and macOS audio capture).
local MONITORED = {
    screen_capture = true,
    sck_audio_capture = true,
}
local BUTTON = "reactivate_capture"

local pending = {}        -- source name -> true, set by the signal callback
local has_pending = false
local hooked = {}         -- source name -> true, to avoid double connections

-- Restarting too early after wake binds the new ScreenCaptureKit stream to a
-- display that isn't lit yet: the stream reports healthy but delivers only
-- black frames, and since no error fires there is no retry. WindowServer
-- brings displays back 1-4 s AFTER processes resume, so instead of guessing
-- with a fixed timer we ask CoreGraphics (via LuaJIT FFI) whether the main
-- display is actually awake and active, and additionally require it to stay
-- that way for `settle_seconds` consecutive ticks before pressing the button.
-- Adjustable in the script's settings UI; raise it if a restarted capture
-- ever comes back black after wake.
local settle_seconds = 2
local ready_streak = 0

local display_ready -- forward declaration
do
    local ok, fn = pcall(function()
        local ffi = require("ffi")
        ffi.cdef([[
            typedef uint32_t CGDirectDisplayID;
            CGDirectDisplayID CGMainDisplayID(void);
            uint32_t CGDisplayIsAsleep(CGDirectDisplayID display);
            uint32_t CGDisplayIsActive(CGDirectDisplayID display);
        ]])
        local CG = ffi.load("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        return function()
            local id = CG.CGMainDisplayID()
            return CG.CGDisplayIsActive(id) ~= 0 and CG.CGDisplayIsAsleep(id) == 0
        end
    end)
    if ok then
        display_ready = fn
    else
        -- FFI unavailable for some reason: fall back to "always ready" and
        -- rely purely on the settle countdown (raise it in the settings).
        display_ready = function() return true end
    end
end

local function log(msg)
    obs.script_log(obs.LOG_INFO, msg)
end

-- The actual (expensive) check-and-fix. Only runs after a failure signal.
local function try_fix(source)
    local props = obs.obs_source_properties(source)
    if props == nil then return end
    local btn = obs.obs_properties_get(props, BUTTON)
    if btn ~= nil and obs.obs_property_enabled(btn) then
        obs.obs_property_button_clicked(btn, source)
        log("Restarted frozen capture: " .. obs.obs_source_get_name(source))
    end
    obs.obs_properties_destroy(props)
end

-- Signal callback: may run on the capture thread, so do nothing but flag.
local function on_update_properties(cd)
    local source = obs.calldata_source(cd, "source")
    if source ~= nil then
        pending[obs.obs_source_get_name(source)] = true
        has_pending = true
        ready_streak = 0
    end
end

local function hook_source(source)
    local id = obs.obs_source_get_unversioned_id(source)
    if not MONITORED[id] then return end
    local name = obs.obs_source_get_name(source)
    if hooked[name] then return end
    local sh = obs.obs_source_get_signal_handler(source)
    obs.signal_handler_connect(sh, "update_properties", on_update_properties)
    hooked[name] = true
    log("Watching capture source: " .. name)
end

local function on_source_create(cd)
    local source = obs.calldata_source(cd, "source")
    if source ~= nil then hook_source(source) end
end

-- Forget destroyed sources, or a recreated source with the same name (e.g.
-- after a scene collection switch) would be skipped as "already hooked"
-- while its actual signal connection died with the old source.
local function on_source_destroy(cd)
    local source = obs.calldata_source(cd, "source")
    if source ~= nil then
        local name = obs.obs_source_get_name(source)
        hooked[name] = nil
        pending[name] = nil
    end
end

-- Cheap 1 s heartbeat: a table lookup while healthy, real work only when
-- a failure was signalled (and once at startup for already-failed sources).
local initial_check_done = false

local function tick()
    if not initial_check_done then
        initial_check_done = true
        local sources = obs.obs_enum_sources()
        if sources ~= nil then
            for _, source in ipairs(sources) do
                hook_source(source)
                if MONITORED[obs.obs_source_get_unversioned_id(source)] then
                    try_fix(source)
                end
            end
            obs.source_list_release(sources)
        end
        return
    end

    if not has_pending then return end

    -- Gate on real display state: only act once the display has been awake
    -- and active for `settle_seconds` consecutive ticks.
    if display_ready() then
        ready_streak = ready_streak + 1
    else
        ready_streak = 0
        return
    end
    if ready_streak < settle_seconds then return end

    local names = pending
    pending = {}
    has_pending = false
    for name in pairs(names) do
        local source = obs.obs_get_source_by_name(name)
        if source ~= nil then
            if MONITORED[obs.obs_source_get_unversioned_id(source)] then
                try_fix(source)
            end
            obs.obs_source_release(source)
        end
    end
end

function script_description()
    return "Automatically restarts frozen macOS screen/audio captures when " ..
           "OBS marks them as failed (wake from sleep, display changes, ...). " ..
           "Event-driven: no polling, no periodic stutter in recordings."
end

function script_properties()
    local props = obs.obs_properties_create()
    local p = obs.obs_properties_add_int(props, "settle_seconds",
                                         "Settle time after display wakes (seconds)", 1, 30, 1)
    obs.obs_property_set_long_description(p,
        "After a capture fails, the restart waits until macOS reports the " ..
        "display awake AND active, then this many extra seconds. Raise it " ..
        "only if a restarted capture ever comes back black after wake.")
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "settle_seconds", 2)
end

function script_update(settings)
    settle_seconds = obs.obs_data_get_int(settings, "settle_seconds")
    if settle_seconds < 1 then settle_seconds = 2 end
end

function script_load(_settings)
    obs.signal_handler_connect(obs.obs_get_signal_handler(), "source_create", on_source_create)
    obs.signal_handler_connect(obs.obs_get_signal_handler(), "source_destroy", on_source_destroy)
    -- Delay the initial scan one tick so sources exist when OBS loads us early.
    obs.timer_add(tick, 1000)
    log("Capture restarter active (event-driven, no polling)")
end

function script_unload()
    obs.timer_remove(tick)
    obs.signal_handler_disconnect(obs.obs_get_signal_handler(), "source_create", on_source_create)
    obs.signal_handler_disconnect(obs.obs_get_signal_handler(), "source_destroy", on_source_destroy)
    for name in pairs(hooked) do
        local source = obs.obs_get_source_by_name(name)
        if source ~= nil then
            obs.signal_handler_disconnect(obs.obs_source_get_signal_handler(source), "update_properties",
                                          on_update_properties)
            obs.obs_source_release(source)
        end
    end
end
