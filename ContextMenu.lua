----------------------------------------------------------------------
-- VoidCalendar ContextMenu — cursor-positioned dropdown for right-clicks.
-- Each item: { label = "...", callback = function() ... end, separator = bool? }
--
-- Auto-scrolling: if items > MAX_VISIBLE (5), shows a scroll frame.
-- Pass `maxVisible` in second arg to override.
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

local VC = VoidCalendar
local ContextMenu = VC:NewModule("ContextMenu")
VC.ContextMenu = ContextMenu

local P = VC.palette
local menu

local ITEM_H = 22
local SEP_H = 8
local DEFAULT_VISIBLE = 5  -- show this many items before enabling scroll
local NARROW_W = 200       -- short-list menu width
local WIDE_W   = 320       -- scrollable menu width (room for long labels + scrollbar)

local function build()
    if menu then return menu end
    menu = CreateFrame("Frame", "VoidCalendarContextMenu", UIParent, "BackdropTemplate")
    menu:SetFrameStrata("TOOLTIP")
    menu:SetSize(200, 90)
    VC:CreateBackdrop(menu, "dark")
    menu:SetBackdropColor(0, 0, 0, 0.95)
    menu:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.7)
    menu:Hide()
    menu._items = {}

    -- Scroll container (shown only when items > maxVisible)
    local scroll = CreateFrame("ScrollFrame", "VoidCalendarContextMenuScroll", menu, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -24, 4)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(170, 200)
    scroll:SetScrollChild(content)
    menu._scroll = scroll
    menu._content = content
    -- Enable wheel scroll on the menu itself too
    menu:EnableMouseWheel(true)
    menu:SetScript("OnMouseWheel", function(self, delta)
        if scroll:IsShown() then
            local cur = scroll:GetVerticalScroll() or 0
            local newScroll = math.max(0, cur - delta * ITEM_H * 2)
            local max = scroll:GetVerticalScrollRange() or 0
            if newScroll > max then newScroll = max end
            scroll:SetVerticalScroll(newScroll)
        end
    end)

    menu:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" then
            if not self:IsMouseOver() then self:Hide() end
        end
    end)
    menu:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    menu:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    return menu
end

local function clearItems()
    for _, item in ipairs(menu._items) do
        item:Hide()
        item:ClearAllPoints()
    end
end

local function makeItem(parent, idx, label, onClick, isSeparator)
    if not parent._items[idx] then
        local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
        local lbl = b:CreateFontString(nil, "OVERLAY")
        VC:SetFont(lbl, 11, "")
        lbl:SetPoint("LEFT", 8, 0)
        lbl:SetPoint("RIGHT", -8, 0)
        lbl:SetJustifyH("LEFT")
        lbl:SetWordWrap(false)        -- never wrap; truncate if too long
        lbl:SetNonSpaceWrap(false)
        b._lbl = lbl
        local hl = b:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints()
        hl:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 0.2)
        hl:Hide()
        b._hl = hl
        b:SetScript("OnEnter", function() if not b._isSep then hl:Show() end end)
        b:SetScript("OnLeave", function() hl:Hide() end)
        parent._items[idx] = b
    end
    local b = parent._items[idx]
    b._lbl:SetText(label or "")
    b._isSep = isSeparator and true or false
    if isSeparator then
        b._lbl:SetTextColor(P.textDim[1], P.textDim[2], P.textDim[3])
        b:SetHeight(SEP_H)
        b:EnableMouse(false)
        b:SetScript("OnClick", nil)
    else
        b._lbl:SetTextColor(P.text[1], P.text[2], P.text[3])
        b:SetHeight(ITEM_H)
        b:EnableMouse(true)
        b:SetScript("OnClick", function()
            menu:Hide()
            if onClick then onClick() end
        end)
    end
    return b
end

-- Show context menu at cursor.
--   items     : { {label, callback, separator?}, ... }
--   maxVisible: optional. Show scroll if items > this. Default 5.
function ContextMenu:Show(items, maxVisible)
    if not items or #items == 0 then
        dbg("ContextMenu:Show called with empty items — ignoring")
        if menu then menu:Hide() end
        return
    end
    build()
    clearItems()

    local n = #items
    local visibleLimit = maxVisible or DEFAULT_VISIBLE
    local useScroll = n > visibleLimit

    local maxH = 0
    if useScroll then
        -- Wide menu so long TZ labels fit comfortably with no wrap/truncation
        maxH = visibleLimit * ITEM_H + 8
        menu:SetSize(WIDE_W, maxH)
        menu._scroll:Show()
        local content = menu._content
        local contentW = WIDE_W - 4 - 24  -- account for left margin + scrollbar
        content:SetWidth(contentW)
        local totalH = 4
        for i, it in ipairs(items) do
            local b = makeItem(menu, i, it.label, it.callback, it.separator)
            b:SetParent(content)
            b:ClearAllPoints()
            b:SetSize(contentW, it.separator and SEP_H or ITEM_H)
            b:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(totalH - 4))
            b:Show()
            local h = it.separator and SEP_H or ITEM_H
            totalH = totalH + h
        end
        content:SetHeight(math.max(totalH, maxH))
        menu._scroll:SetVerticalScroll(0)
    else
        menu._scroll:Hide()
        menu:SetSize(NARROW_W, 8)  -- temporary; resize below
        local yOff = 4
        local totalH = 8
        for i, it in ipairs(items) do
            local b = makeItem(menu, i, it.label, it.callback, it.separator)
            b:SetParent(menu)
            b:ClearAllPoints()
            b:SetPoint("LEFT", menu, "LEFT", 4, 0)
            b:SetPoint("RIGHT", menu, "RIGHT", -4, 0)
            b:SetPoint("TOP", menu, "TOP", 0, -yOff)
            b:Show()
            local h = it.separator and SEP_H or ITEM_H
            yOff = yOff + h
            totalH = totalH + h
        end
        menu:SetSize(NARROW_W, totalH)
    end

    -- Position at cursor
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    menu:Show()
end

function ContextMenu:Hide()
    if menu then menu:Hide() end
end

function ContextMenu:Init()
    build()
end
