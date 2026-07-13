-- Phase 4: ns.UI.Debounce - the cancel-and-reschedule primitive behind the
-- debounced resize re-renders, perk search, and editor cosmetic refresh.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

-- A C_Timer.NewTimer stub that records every timer and whether it was cancelled.
local timers = {}
C_Timer = {
    NewTimer = function(_, fn)
        local t = { fn = fn, cancelled = false }
        t.Cancel = function() t.cancelled = true end
        timers[#timers + 1] = t
        return t
    end,
}

local ns = {}
T.load(ns, "UI/Window.lua")
local UI = ns.UI

-- A burst of calls schedules a timer each, cancels all but the last, and runs fn
-- exactly once with the final call's arguments when the survivor fires.
local calls, last = 0, nil
local d = UI.Debounce(0.2, function(x) calls = calls + 1; last = x end)
d("a"); d("b"); d("c")
assert(#timers == 3, "each call should schedule a timer")
assert(timers[1].cancelled and timers[2].cancelled, "earlier timers must be cancelled")
assert(not timers[3].cancelled, "the last timer must survive")
timers[3].fn()
assert(calls == 1 and last == "c", "fn runs once, with the last call's args")

-- After firing, the next call schedules a fresh timer (the handle was cleared).
d("d")
assert(#timers == 4 and not timers[4].cancelled, "a post-fire call reschedules")
timers[4].fn()
assert(calls == 2 and last == "d")

-- Fallback: with no C_Timer, the wrapper runs fn immediately (the out-of-client
-- path, and a safe degrade in-game if the API is ever missing).
C_Timer = nil
local immediate = 0
local d2 = UI.Debounce(0.2, function() immediate = immediate + 1 end)
d2(); d2()
assert(immediate == 2, "without C_Timer the call must run immediately")
