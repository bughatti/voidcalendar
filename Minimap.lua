----------------------------------------------------------------------
-- VoidCalendar Minimap Icon — matches the standardized Void* spec.
----------------------------------------------------------------------

VoidCalendar = VoidCalendar or {}

local minimapBtn

local function PositionButton(btn)
    VoidCalendarCharDB = VoidCalendarCharDB or {}
    local angle = math.rad(VoidCalendarCharDB.minimapAngle or 195)
    local radius = (Minimap:GetWidth() / 2) + 6
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
end

local function CreateMinimapButton()
    if minimapBtn then return minimapBtn end
    if not Minimap then return nil end

    local btn = CreateFrame("Button", "VoidCalendarMinimapBtn", Minimap)
    btn:SetSize(28, 28)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 10)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_03")  -- calendar/note icon
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            -- Right-click opens Blizzard's native calendar (one-shot)
            VoidCalendar._allowBlizz = true
            if VoidCalendar.Hooks and VoidCalendar.Hooks.OpenBlizzCalendar then
                VoidCalendar.Hooks:OpenBlizzCalendar()
            end
            C_Timer.After(2, function() VoidCalendar._allowBlizz = false end)
        else
            -- Left-click opens VoidCalendar
            if VoidCalendar.Calendar and VoidCalendar.Calendar.Toggle then
                VoidCalendar.Calendar:Toggle()
            end
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("|cff00c7ffVoidCalendar|r")
        GameTooltip:AddLine("Left-click: open VoidCalendar", 1, 1, 1)
        GameTooltip:AddLine("Right-click: open Blizzard's calendar", 1, 1, 1)
        GameTooltip:AddLine("Drag: reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self) self._dragging = true end)
    btn:SetScript("OnDragStop",  function(self) self._dragging = false end)
    btn:SetScript("OnUpdate", function(self)
        if self._dragging then
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local px, py = GetCursorPosition()
            px = px / scale; py = py / scale
            VoidCalendarCharDB = VoidCalendarCharDB or {}
            VoidCalendarCharDB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            PositionButton(self)
        end
    end)

    PositionButton(btn)
    minimapBtn = btn
    return btn
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() CreateMinimapButton() end)
