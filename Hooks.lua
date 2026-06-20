----------------------------------------------------------------------
-- VoidCalendar Hooks — intercept Blizzard's calendar
--
-- We don't UNLOAD Blizzard_Calendar (it owns the C_Calendar data we
-- consume). We intercept the toggle path so the Y key, the minimap
-- icon, and macro/UIPanelLayouts open OUR frame instead.
--
-- When Blizzard's CalendarFrame would Show, we cancel and show ours.
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

local VC = VoidCalendar
local Hooks = VC:NewModule("Hooks")
VC.Hooks = Hooks

local function installFrameHook()
    -- The Blizzard_Calendar addon may load lazily on first Y press. Wait for it.
    if not CalendarFrame then return false end
    if CalendarFrame._voidHooked then return true end

    CalendarFrame:HookScript("OnShow", function(self)
        if not VC:GetDB().enabled then return end
        -- TESTING: if user has run `/vc bliz`, allow Blizzard's calendar to
        -- show alongside ours instead of intercepting. Used for side-by-side
        -- comparison + debugging.
        if VC._allowBlizz then return end
        -- Hide Blizzard's frame and open ours
        self:Hide()
        VC.Calendar:Show()
    end)

    CalendarFrame._voidHooked = true
    dbg("Hooked CalendarFrame:OnShow → routes to VoidCalendar")
    return true
end

-- Also intercept ToggleCalendar() so even raw API calls route correctly.
local _origToggle
local function installToggleHook()
    if _origToggle then return end
    if not ToggleCalendar then return end
    _origToggle = ToggleCalendar
    ToggleCalendar = function(...)
        if not VC:GetDB().enabled then return _origToggle(...) end
        if VC._allowBlizz then return _origToggle(...) end  -- testing mode
        VC.Calendar:Toggle()
    end
    dbg("Hooked ToggleCalendar()")
end

-- Public helper: open Blizzard's calendar even when intercepting (uses original toggle)
function VC.Hooks:OpenBlizzCalendar()
    if _origToggle then
        _origToggle()
    elseif ToggleCalendar then
        ToggleCalendar()
    end
end

----------------------------------------------------------------------
-- ADDON_LOADED for Blizzard_Calendar — Blizzard's calendar is a lazy-load
-- LOD addon. Hook into it once it loads.
----------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "Blizzard_Calendar" then
        installFrameHook()
        installToggleHook()
    elseif event == "PLAYER_LOGIN" then
        -- Try to hook (if Blizzard_Calendar already loaded)
        installToggleHook()
        if not installFrameHook() then
            -- Force-load Blizzard's calendar then hook
            if C_AddOns and C_AddOns.LoadAddOn then
                C_AddOns.LoadAddOn("Blizzard_Calendar")
            elseif LoadAddOn then
                LoadAddOn("Blizzard_Calendar")
            end
            -- Try hook again after load
            installFrameHook()
            installToggleHook()
        end
    end
end)

function Hooks:Init()
    -- Mostly handled by event-driven installation above
end
