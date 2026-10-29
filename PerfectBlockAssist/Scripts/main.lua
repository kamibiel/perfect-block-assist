--[[
    PerfectBlockAssist - Grounded 2 (UE4SS Lua)
    A timing helper for the Perfect Block. When an enemy near you starts a melee attack, a bar under the
    crosshair shows how long until the hit lands. A green zone at the end of the bar marks the game's
    own Perfect Block window: start blocking while the marker is inside it.

    Two modes, chosen in the in-game menu (F6):
      - Timing bar: the mod only reads the game, you still block by hand.
      - Every block is perfect: the game's Perfect Block window is made very long, so any block that
        takes a hit counts as a Perfect Block (the original window comes back when you switch modes).

    How it predicts the hit: when an enemy starts an attack, the game plays an animation montage for it.
    The hit itself is an animation notify inside that montage (HitFrame / HitActive / MultiHitFrame).
    Every frame the mod reads where the montage is and how fast it plays, so the countdown follows
    combos, speed changes and interrupted attacks.
--]]

local VERSION = "1.0.0"

local Config = {
    LeadTime     = 1.0,    -- seconds before the hit when the bar appears
    MaxDistance  = 2500,   -- cm (25 m): only attacks from enemies this close are shown
    FacingDot    = 0.30,   -- the enemy must be facing you (1 = straight at you, 0 = 90 degrees)
    WindowOverride = 0,    -- seconds; 0 = use the game's own Perfect Block window
    BarWidth     = 340,
    BarHeight    = 8,
    OffsetY      = 120,    -- pixels below the screen centre
    TextSize     = 22,
    BlockText    = "BLOCK!",
    Latency      = 0.012,  -- seconds: the bar runs this much ahead to make up for the update delay (measured in game)
    Ignore       = { "DiveBomb" }, -- attacks whose hit does not follow the animation (the dive hits on contact)
    DumpNotifies = false,  -- log every notify of each new attack animation (for adding new enemies)
    LoopMs       = 16,     -- update rate (about 60 times per second)
    Verbose      = false,  -- log every attack and block (to check the timing)
}

local function log(fmt, ...)
    print(string.format("[PerfectBlockAssist] " .. fmt .. "\n", ...))
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function addr(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    return ok and tostring(a) or nil
end

local function shortName(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or "?"
end

local function className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

local Classes = {}
local function cls(path)
    local c = Classes[path]
    if valid(c) then return c end
    c = StaticFindObject(path)
    if valid(c) then Classes[path] = c return c end
    return nil
end

-- FAnimLinkableElement::GetTime(): Absolute = LinkValue, Relative = segment start + LinkValue,
-- Proportional = segment start + segment length * LinkValue.
local function linkTime(e)
    local method = tonumber(e.LinkMethod) or 0
    local v = tonumber(e.LinkValue) or 0
    local sb = tonumber(e.SegmentBeginTime) or 0
    local sl = tonumber(e.SegmentLength) or 0
    if method == 1 then return sb + v end
    if method == 2 then return sb + v * sl end
    return v
end

local HIT_PATTERNS = { "HitFrame", "HitActive" }

local function nameMatches(n)
    for _, p in ipairs(HIT_PATTERNS) do
        if n:find(p, 1, true) then return true end
    end
    return false
end

-- Is this notify event a hit? Returns hit, description (for the log).
local function classifyNotify(ev)
    local n, s = ev.Notify, ev.NotifyStateClass
    local desc = "?"
    if valid(n) then
        desc = className(n)
        local c = cls("/Script/Maine.AnimNotify_HitFrame")
        if (c and n:IsA(c)) or nameMatches(desc) then return true, desc end
    end
    if valid(s) then
        desc = className(s)
        local a = cls("/Script/Maine.AnimNotifyState_HitActive")
        local m = cls("/Script/Maine.AnimNotifyState_MultiHitFrame")
        if (a and s:IsA(a)) or (m and s:IsA(m)) or nameMatches(desc) then return true, desc end
    end
    local okN, nn = pcall(function() return ev.NotifyName:ToString() end)
    if okN and nn and nn ~= "None" then
        desc = desc .. "/" .. nn
        if nameMatches(nn) then return true, desc end
    end
    return false, desc
end

---------------------------------------------------------------------------
-- Montage analysis (cached per montage)
---------------------------------------------------------------------------
local MontageCache = {}
local Diagnosed = {}

-- Notifies of one asset; each found time is passed to add(time, desc, hit).
local function readNotifies(asset, add)
    pcall(function()
        asset.Notifies:ForEach(function(_, el)
            local ev = el:get()
            local hit, desc = classifyNotify(ev)
            add(linkTime(ev) + (tonumber(ev.TriggerTimeOffset) or 0), desc, hit)
        end)
    end)
end

local function analyse(m)
    local key = addr(m)
    local c = key and MontageCache[key]
    if c then return c end
    c = { name = shortName(m), hits = {}, sections = {}, length = 0 }
    pcall(function() c.length = m:GetPlayLength() end)
    local diag = Config.DumpNotifies and not Diagnosed[c.name] and c.name:find("Attack", 1, true) ~= nil
    Diagnosed[c.name] = true
    local seen = {}
    local function addHit(t)
        local k = string.format("%.3f", t)
        if not seen[k] then seen[k] = true table.insert(c.hits, t) end
    end
    -- 1) notifies placed on the montage itself
    readNotifies(m, function(t, desc, hit)
        if hit then addHit(t) end
        if diag then log("  %s notify %.2f %s%s", c.name, t, desc, hit and " <HIT>" or "") end
    end)
    -- 2) notifies inside the animation sequences the montage plays
    pcall(function()
        m.SlotAnimTracks:ForEach(function(_, tr)
            local track = tr:get()
            track.AnimTrack.AnimSegments:ForEach(function(_, sg)
                local seg = sg:get()
                local seq = seg.AnimReference
                if not valid(seq) then return end
                local startPos = tonumber(seg.StartPos) or 0
                local a0 = tonumber(seg.AnimStartTime) or 0
                local a1 = tonumber(seg.AnimEndTime) or 1e9
                local rate = tonumber(seg.AnimPlayRate) or 1
                if rate <= 0 then rate = 1 end
                readNotifies(seq, function(t, desc, hit)
                    local inside = t >= a0 - 0.001 and t <= a1 + 0.001
                    local mt = startPos + (t - a0) / rate
                    if hit and inside then addHit(mt) end
                    if diag then
                        log("  %s seq %s notify %.2f (montage %.2f) %s%s", c.name, shortName(seq), t, mt, desc,
                            hit and (inside and " <HIT>" or " <HIT outside segment>") or "")
                    end
                end)
            end)
        end)
    end)
    for _, word in ipairs(Config.Ignore or {}) do
        if c.name:find(word, 1, true) then c.hits = {} c.ignored = true end
    end
    table.sort(c.hits)
    pcall(function()
        m.CompositeSections:ForEach(function(_, el)
            local s = el:get()
            table.insert(c.sections, { name = s.SectionName:ToString(), next = s.NextSectionName:ToString(),
                start = linkTime(s) })
        end)
    end)
    table.sort(c.sections, function(a, b) return a.start < b.start end)
    for i, s in ipairs(c.sections) do
        s.stop = c.sections[i + 1] and c.sections[i + 1].start or c.length
    end
    if key then MontageCache[key] = c end
    if Config.Verbose and (diag or #c.hits > 0) then
        local hs = {}
        for _, h in ipairs(c.hits) do hs[#hs + 1] = string.format("%.2f", h) end
        local ss = {}
        for _, s in ipairs(c.sections) do ss[#ss + 1] = string.format("%s@%.2f>%s", s.name, s.start, s.next) end
        log("montage %s: length %.2f, hits {%s}, sections {%s}", c.name, c.length, table.concat(hs, " "),
            table.concat(ss, " "))
    end
    return c
end

local function sectionByName(c, name)
    for _, s in ipairs(c.sections) do if s.name == name then return s end end
    return nil
end

-- Montage time until the next hit (follows the section chain, at most 4 sections ahead); nil = no more hits.
local function montageTimeToHit(c, pos)
    if #c.hits == 0 then return nil end
    local cur
    for _, s in ipairs(c.sections) do
        if pos >= s.start - 0.001 and pos < s.stop then cur = s break end
    end
    if not cur then
        for _, h in ipairs(c.hits) do if h >= pos then return h - pos end end
        return nil
    end
    local acc, from = 0, pos
    for _ = 1, 4 do
        for _, h in ipairs(c.hits) do
            if h >= from and h < cur.stop then return acc + (h - from) end
        end
        if not cur.next or cur.next == "None" or cur.next == "" then return nil end
        local nx = sectionByName(c, cur.next)
        if not nx then return nil end
        acc = acc + (cur.stop - from)
        from, cur = nx.start, nx
    end
    return nil
end

---------------------------------------------------------------------------
-- Settings (config.ini next to the Scripts folder; written by the in-game menu)
---------------------------------------------------------------------------
local MODES = { "bar", "perfect", "off" }
local SIZES = { small = 260, medium = 340, large = 440 }
local SIZE_ORDER = { "small", "medium", "large" }
Config.Mode = "bar"
Config.BarSize = "medium"
Config.MenuKey = "F6"
Config.Language = "auto"

local MOD_DIR = (function()
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and src then
        src = src:gsub("^@", "")
        local dir = src:match("^(.*[\\/])Scripts[\\/][^\\/]*$")
        if dir then return dir end
    end
    return "ue4ss/Mods/PerfectBlockAssist/"
end)()
local SETTINGS_FILE = MOD_DIR .. "config.ini"

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function loadSettings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return false end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and v ~= "" then
            if k == "Mode" then
                for _, m in ipairs(MODES) do if m == v then Config.Mode = v end end
            elseif k == "LeadTime" and tonumber(v) then Config.LeadTime = clamp(tonumber(v), 0.5, 2.0)
            elseif k == "BarSize" and SIZES[v] then Config.BarSize = v
            elseif k == "OffsetY" and tonumber(v) then Config.OffsetY = clamp(math.floor(tonumber(v)), -300, 400)
            elseif k == "MenuKey" then Config.MenuKey = v:upper()
            elseif k == "Language" then Config.Language = v:lower()
            end
        end
    end
    f:close()
    return true
end

local function saveSettings()
    local f = io.open(SETTINGS_FILE, "w")
    if not f then log("could not write %s", SETTINGS_FILE) return end
    f:write("; PerfectBlockAssist settings - also changed by the in-game menu (" .. Config.MenuKey .. ")\n")
    f:write("; Mode: bar = timing bar, perfect = every block is a Perfect Block, off = mod does nothing\n")
    f:write("Mode = " .. Config.Mode .. "\n")
    f:write("; Seconds before the hit when the bar appears (0.5 - 2.0)\n")
    f:write(string.format("LeadTime = %.1f\n", Config.LeadTime))
    f:write("; small, medium or large\n")
    f:write("BarSize = " .. Config.BarSize .. "\n")
    f:write("; Pixels below the screen centre (negative = above)\n")
    f:write(string.format("OffsetY = %d\n", Config.OffsetY))
    f:write("; Key that opens the menu: F1 - F12\n")
    f:write("MenuKey = " .. Config.MenuKey .. "\n")
    f:write("; auto (follows the game), en or pt-br\n")
    f:write("Language = " .. Config.Language .. "\n")
    f:close()
end

if not loadSettings() then saveSettings() end
Config.BarWidth = SIZES[Config.BarSize] or 340

-- Language: auto follows the game's LanguageSetting in GameUserSettings.ini
local function detectLanguage()
    if Config.Language == "en" or Config.Language == "pt-br" then return Config.Language end
    local base = os.getenv("LOCALAPPDATA")
    if base then
        local f = io.open(base .. "\\Augusta\\Saved\\Config\\Windows\\GameUserSettings.ini", "r")
        if f then
            local text = f:read("a") or ""
            f:close()
            local lang = text:match("LanguageSetting=([%w_]+)")
            if lang and lang:lower():find("portug") then return "pt-br" end
        end
    end
    return "en"
end
local LANG = detectLanguage()

local TEXT = {
    ["en"] = {
        title = "Perfect Block Assist", mode = "Mode", lead = "Bar lead time", size = "Bar size", pos = "Bar position",
        bar = "Timing bar", perfect = "Every block is perfect", off = "Off",
        small = "Small", medium = "Medium", large = "Large",
        seconds = "%.1f s", pixels = "%d px",
        hint = "Up/Down: choose   Left/Right: change   %s: close",
        note_bar = "Block when the marker reaches the green zone.",
        note_perfect = "Any block that takes a hit counts as a Perfect Block.",
        note_off = "The mod does nothing.",
        block = "BLOCK!",
    },
    ["pt-br"] = {
        title = "Perfect Block Assist", mode = "Modo", lead = "Antecedência da barra", size = "Tamanho da barra",
        pos = "Posição da barra",
        bar = "Barra de tempo", perfect = "Todo bloqueio é perfeito", off = "Desligado",
        small = "Pequena", medium = "Média", large = "Grande",
        seconds = "%.1f s", pixels = "%d px",
        hint = "Cima/Baixo: escolher   Esquerda/Direita: alterar   %s: fechar",
        note_bar = "Bloqueie quando o marcador chegar na faixa verde.",
        note_perfect = "Todo bloqueio que receber um golpe conta como perfeito.",
        note_off = "O mod não faz nada.",
        block = "BLOQUEIE!",
    },
}
local function T(key) return (TEXT[LANG] or TEXT.en)[key] or key end
Config.BlockText = T("block")

---------------------------------------------------------------------------
-- Player
---------------------------------------------------------------------------
local S = {
    pawn = nil, pawnAt = 0,
    window = 0.25,
    best = nil,       -- { tth, name }
    demoUntil = 0, demoStart = 0,
}

local function now() return os.clock() end

-- "Every block is perfect": the game counts a block as perfect when the hit lands within
-- PerfectBlockWindow seconds after the block started, so a very large window makes every block perfect.
local BIG_WINDOW = 9999
local Perfect = { saved = {} } -- block component address -> { comp, window, mounted }

local function restorePerfect()
    for key, e in pairs(Perfect.saved) do
        if valid(e.comp) then
            pcall(function()
                e.comp.PerfectBlockWindow = e.window
                e.comp.PerfectBlockWindowMounted = e.mounted
            end)
            log("perfect mode off: window back to %.0f ms", e.window * 1000)
        end
        Perfect.saved[key] = nil
    end
end

local function applyPerfect(pawn)
    local ok, bc = pcall(function() return pawn.BlockComponent end)
    if not ok or not valid(bc) then return end
    local key = addr(bc)
    if not key then return end
    if not Perfect.saved[key] then
        local okW, w, wm = pcall(function() return bc.PerfectBlockWindow, bc.PerfectBlockWindowMounted end)
        if not okW or type(w) ~= "number" or w >= BIG_WINDOW then return end
        Perfect.saved[key] = { comp = bc, window = w, mounted = wm }
        log("perfect mode on (game window was %.0f ms)", w * 1000)
    end
    pcall(function()
        if bc.PerfectBlockWindow ~= BIG_WINDOW then
            bc.PerfectBlockWindow = BIG_WINDOW
            bc.PerfectBlockWindowMounted = BIG_WINDOW
        end
    end)
end

local function player()
    if valid(S.pawn) and now() - S.pawnAt < 2 then return S.pawn end
    S.pawn = nil
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local ok, isLocal = pcall(function() return pc:IsLocalController() end)
        if ok and isLocal then
            local p = pc.Pawn
            if valid(p) then S.pawn = p break end
        end
    end
    S.pawnAt = now()
    if S.pawn then
        pcall(function()
            local bc = S.pawn.BlockComponent
            local saved = Perfect.saved[addr(bc)]
            local w = saved and saved.window or bc.PerfectBlockWindow
            if type(w) == "number" and w > 0 and w < BIG_WINDOW then S.window = w end
        end)
    end
    return S.pawn
end

local function window()
    if Config.WindowOverride and Config.WindowOverride > 0 then return Config.WindowOverride end
    return S.window
end

local function vec(o) return { X = o.X, Y = o.Y, Z = o.Z } end

-- Is this attacker a nearby enemy facing the player? Returns ok, distance.
local function threatens(char, pawn)
    local okP, isPlayer = pcall(function() return char:IsPlayerControlled() end)
    if okP and isPlayer then return false end
    if addr(char) == addr(pawn) then return false end
    local ok, a, p, f = pcall(function()
        return vec(char:K2_GetActorLocation()), vec(pawn:K2_GetActorLocation()), vec(char:GetActorForwardVector())
    end)
    if not ok then return false end
    local dx, dy, dz = p.X - a.X, p.Y - a.Y, p.Z - a.Z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > Config.MaxDistance then return false, dist end
    local flat = math.sqrt(dx * dx + dy * dy)
    if flat > 150 then
        local dot = (f.X * dx + f.Y * dy) / flat
        if dot < Config.FacingDot then return false, dist end
    end
    return true, dist
end

---------------------------------------------------------------------------
-- HUD (UMG widgets added to the game's HUD canvas)
---------------------------------------------------------------------------
local UI = { built = false }
local VIS_SHOWN, VIS_COLLAPSED = 3, 1 -- HitTestInvisible, Collapsed

local function findCanvas()
    local canvasClass = cls("/Script/UMG.CanvasPanel")
    local contentClass = cls("/Script/UMG.ContentWidget")
    local panelClass = cls("/Script/UMG.PanelWidget")
    if not (canvasClass and contentClass and panelClass) then return nil end
    for _, hud in ipairs(FindAllOf("HUDWidget") or {}) do
        local ok, inView = pcall(function() return valid(hud) and hud:IsInViewport() end)
        if ok and inView then
            local root = hud.WidgetTree and hud.WidgetTree.RootWidget
            if valid(root) then
                local queue = { { root, 0 } }
                while #queue > 0 do
                    local w, depth = table.unpack(table.remove(queue, 1))
                    if w:IsA(canvasClass) then return hud, w end
                    if depth < 4 then
                        if w:IsA(contentClass) then
                            local c = w:GetContent()
                            if valid(c) then queue[#queue + 1] = { c, depth + 1 } end
                        elseif w:IsA(panelClass) then
                            for i = 0, w:GetChildrenCount() - 1 do
                                local c = w:GetChildAt(i)
                                if valid(c) then queue[#queue + 1] = { c, depth + 1 } end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local widgetCount = 0
local function newWidget(kind)
    widgetCount = widgetCount + 1
    local c = cls("/Script/UMG." .. kind)
    return StaticConstructObject(c, UI.hud.WidgetTree, FName(string.format("PBA_%s_%d_%d", kind, os.time(), widgetCount)))
end

local function place(w, x, y, width, height, z, alignX)
    local slot = UI.canvas:AddChildToCanvas(w)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    slot:SetAlignment({ X = alignX or 0.5, Y = 0.5 })
    if width then
        slot:SetAutoSize(false)
        slot:SetSize({ X = width, Y = height })
    else
        slot:SetAutoSize(true)
    end
    slot:SetPosition({ X = x, Y = y })
    slot:SetZOrder(z or 50)
    return slot
end

local function rect(color, x, y, width, height, z)
    local img = newWidget("Image")
    img:SetColorAndOpacity(color)
    img:SetVisibility(VIS_COLLAPSED)
    return img, place(img, x, y, width, height, z)
end

local function textColor(tb, r, g, b, a)
    tb:SetColorAndOpacity({ SpecifiedColor = { R = r, G = g, B = b, A = a or 1 }, ColorUseRule = 0 })
end

local function label(text, size, x, y, z, alignX)
    local tb = newWidget("TextBlock")
    tb:SetText(FText(text))
    local f = tb.Font
    f.Size = size
    tb:SetFont(f)
    pcall(function() tb:SetShadowOffset({ X = 1.5, Y = 1.5 }) end)
    pcall(function() tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 }) end)
    textColor(tb, 1, 1, 1, 1)
    tb:SetVisibility(VIS_COLLAPSED)
    return tb, place(tb, x, y, nil, nil, z, alignX)
end

local Menu -- defined below; build() also builds the menu widgets

local function buildBar()
    local W, H, Y = Config.BarWidth, Config.BarHeight, Config.OffsetY
    UI.track, UI.trackSlot = rect({ R = 0, G = 0, B = 0, A = 0.45 }, 0, Y, W + 6, H + 6, 50)
    UI.zone, UI.zoneSlot = rect({ R = 0.25, G = 0.95, B = 0.35, A = 0.55 }, 0, Y, 10, H, 51)
    UI.hit, UI.hitSlot = rect({ R = 1, G = 0.25, B = 0.2, A = 0.95 }, W / 2, Y, 3, H + 12, 52)
    UI.cursor, UI.cursorSlot = rect({ R = 1, G = 1, B = 1, A = 1 }, -W / 2, Y, 4, H + 14, 53)
    UI.text, UI.textSlot = label(Config.BlockText, Config.TextSize, 0, Y - 26, 54)
    textColor(UI.text, 0.3, 1, 0.4, 1)
    UI.shown, UI.textShown = false, false
end

-- Size or position changed in the menu: move the bar pieces (no rebuild needed)
local function layoutBar()
    if not UI.built then return end
    local W, H, Y = Config.BarWidth, Config.BarHeight, Config.OffsetY
    UI.trackSlot:SetSize({ X = W + 6, Y = H + 6 })
    UI.trackSlot:SetPosition({ X = 0, Y = Y })
    UI.hitSlot:SetPosition({ X = W / 2, Y = Y })
    UI.textSlot:SetPosition({ X = 0, Y = Y - 26 })
end

local function build()
    UI.built = false
    local hud, canvas = findCanvas()
    if not hud then return false end
    UI.hud, UI.canvas = hud, canvas
    buildBar()
    Menu.build()
    UI.built = true
    UI.checkedAt = now()
    log("HUD ready")
    if not S.previewDone and Config.Mode == "bar" then -- short preview so you can see the bar works
        S.previewDone = true
        S.demoStart = now()
        S.demoUntil = now() + 2 * (Config.LeadTime + 0.4)
    end
    return true
end

local function stillAttached()
    local ok, r = pcall(function()
        return valid(UI.hud) and valid(UI.canvas) and valid(UI.cursor) and UI.hud:IsInViewport()
    end)
    return ok and r
end

local function setShown(on)
    if UI.shown == on then return end
    local v = on and VIS_SHOWN or VIS_COLLAPSED
    for _, w in ipairs({ UI.track, UI.zone, UI.hit, UI.cursor }) do pcall(function() w:SetVisibility(v) end) end
    if not on then pcall(function() UI.text:SetVisibility(VIS_COLLAPSED) end) UI.textShown = false end
    UI.shown = on
end

local function draw(tth)
    if not UI.built then return end
    if tth == nil then setShown(false) return end
    local W, Y, lead = Config.BarWidth, Config.OffsetY, Config.LeadTime
    local win = math.min(window(), lead)
    local zoneW = W * win / lead
    UI.zoneSlot:SetSize({ X = zoneW, Y = Config.BarHeight })
    UI.zoneSlot:SetPosition({ X = W / 2 - zoneW / 2, Y = Y })
    local t = math.max(0, math.min(lead, tth))
    UI.cursorSlot:SetPosition({ X = -W / 2 + W * (1 - t / lead), Y = Y })
    local inWindow = tth <= win and tth >= -0.05
    if inWindow ~= UI.textShown then
        UI.text:SetVisibility(inWindow and VIS_SHOWN or VIS_COLLAPSED)
        UI.textShown = inWindow
    end
    setShown(true)
end

---------------------------------------------------------------------------
-- In-game menu (default key F6; Up/Down choose, Left/Right change)
---------------------------------------------------------------------------
Menu = { open = false, row = 1, rows = {} }
local MENU_W, ROW_H = 520, 34
local MENU_TOP = -150

local function cycle(list, current, step)
    local idx = 1
    for i, v in ipairs(list) do if v == current then idx = i end end
    idx = (idx - 1 + step) % #list + 1
    return list[idx]
end

local ITEMS = {
    { key = "mode",
      value = function() return T(Config.Mode) end,
      change = function(step) Config.Mode = cycle(MODES, Config.Mode, step) end },
    { key = "lead",
      value = function() return string.format(T("seconds"), Config.LeadTime) end,
      change = function(step) Config.LeadTime = clamp(math.floor(Config.LeadTime * 10 + step * 1 + 0.5) / 10, 0.5, 2.0) end },
    { key = "size",
      value = function() return T(Config.BarSize) end,
      change = function(step)
          Config.BarSize = cycle(SIZE_ORDER, Config.BarSize, step)
          Config.BarWidth = SIZES[Config.BarSize]
      end },
    { key = "pos",
      value = function() return string.format(T("pixels"), Config.OffsetY) end,
      change = function(step) Config.OffsetY = clamp(Config.OffsetY + step * 20, -300, 400) end },
}

function Menu.build()
    local rowsH = #ITEMS * ROW_H
    local height = 70 + rowsH + 70
    local cy = MENU_TOP + height / 2
    Menu.widgets = {}
    Menu.bg = rect({ R = 0.02, G = 0.03, B = 0.04, A = 0.82 }, 0, cy, MENU_W, height, 90)
    Menu.accent = rect({ R = 0.3, G = 0.9, B = 0.4, A = 0.9 }, 0, MENU_TOP + 2, MENU_W, 4, 91)
    Menu.title = label(T("title"), 24, 0, MENU_TOP + 30, 92)
    textColor(Menu.title, 0.45, 1, 0.55, 1)
    Menu.rows = {}
    for i, item in ipairs(ITEMS) do
        local y = MENU_TOP + 70 + (i - 1) * ROW_H + ROW_H / 2
        local name = label(T(item.key), 18, -MENU_W / 2 + 28, y, 92, 0)
        local value = label("", 18, MENU_W / 2 - 28, y, 92, 1)
        Menu.rows[i] = { name = name, value = value }
    end
    Menu.note = label("", 15, 0, MENU_TOP + 70 + rowsH + 18, 92)
    textColor(Menu.note, 0.8, 0.85, 0.8, 1)
    Menu.hint = label(string.format(T("hint"), Config.MenuKey), 14, 0, MENU_TOP + 70 + rowsH + 46, 92)
    textColor(Menu.hint, 0.65, 0.65, 0.65, 1)
    Menu.all = { Menu.bg, Menu.accent, Menu.title, Menu.note, Menu.hint }
    for _, r in ipairs(Menu.rows) do
        Menu.all[#Menu.all + 1] = r.name
        Menu.all[#Menu.all + 1] = r.value
    end
    Menu.visible = false
    if Menu.open then Menu.refresh() Menu.setVisible(true) end
end

function Menu.refresh()
    if not UI.built and not Menu.rows[1] then return end
    for i, item in ipairs(ITEMS) do
        local r = Menu.rows[i]
        if r then
            local selected = i == Menu.row
            local disabled = item.key ~= "mode" and Config.Mode ~= "bar"
            r.value:SetText(FText((selected and "<  " or "") .. item.value() .. (selected and "  >" or "")))
            local c = selected and { 1, 0.85, 0.3 } or (disabled and { 0.5, 0.5, 0.5 } or { 1, 1, 1 })
            textColor(r.name, c[1], c[2], c[3], 1)
            textColor(r.value, c[1], c[2], c[3], 1)
        end
    end
    Menu.note:SetText(FText(T("note_" .. Config.Mode)))
end

function Menu.setVisible(on)
    if Menu.visible == on or not Menu.all then return end
    for _, w in ipairs(Menu.all) do pcall(function() w:SetVisibility(on and VIS_SHOWN or VIS_COLLAPSED) end) end
    Menu.visible = on
end

function Menu.toggle()
    if not UI.built then return end
    Menu.open = not Menu.open
    if Menu.open then Menu.refresh() end
    Menu.setVisible(Menu.open)
    if not Menu.open then saveSettings() end
end

function Menu.move(step)
    if not Menu.open then return end
    Menu.row = (Menu.row - 1 + step) % #ITEMS + 1
    Menu.refresh()
end

function Menu.change(step)
    if not Menu.open then return end
    ITEMS[Menu.row].change(step)
    layoutBar()
    Menu.refresh()
    saveSettings()
    log("menu: %s = %s", ITEMS[Menu.row].key, ITEMS[Menu.row].value())
end

---------------------------------------------------------------------------
-- Tracking attacks
---------------------------------------------------------------------------
-- The game calls the attack functions natively, so instead of a hook the mod watches the creatures
-- near you: a creature whose current montage contains a hit notify is attacking.
local Creatures = { all = {}, near = {}, scanAt = -100, nearAt = -100 }

local function addCreature(c)
    local key = addr(c)
    if key and not Creatures.all[key] then Creatures.all[key] = { char = c } end
end

local function fullScan()
    Creatures.scanAt = now()
    local t0 = now()
    local n = 0
    for _, c in ipairs(FindAllOf("SurvivalCreature") or {}) do
        if valid(c) then addCreature(c) n = n + 1 end
    end
    if Config.Verbose then log("creature scan: %d creature(s) in %.1f ms", n, (now() - t0) * 1000) end
end

local function refreshNear(pawn)
    Creatures.nearAt = now()
    local okP, p = pcall(function() return vec(pawn:K2_GetActorLocation()) end)
    if not okP then return end
    local near = {}
    local maxD2 = Config.MaxDistance * Config.MaxDistance
    for key, e in pairs(Creatures.all) do
        if not valid(e.char) then
            Creatures.all[key] = nil
        else
            local ok, a = pcall(function() return vec(e.char:K2_GetActorLocation()) end)
            if ok then
                local dx, dy, dz = p.X - a.X, p.Y - a.Y, p.Z - a.Z
                if dx * dx + dy * dy + dz * dz <= maxD2 then near[#near + 1] = e end
            end
        end
    end
    Creatures.near = near
end

-- Seconds until this creature's next hit, or nil when it is not attacking.
local function creatureTimeToHit(e)
    if not valid(e.anim) then
        local ok, anim = pcall(function() return e.char.Mesh:GetAnimInstance() end)
        if not ok or not valid(anim) then return nil end
        e.anim = anim
    end
    local m = e.anim:GetCurrentActiveMontage()
    if not valid(m) then e.montage = nil return nil end
    local info = analyse(m)
    if #info.hits == 0 then e.montage = nil return nil end
    local mk = addr(m)
    if e.montage ~= mk then
        e.montage = mk
        e.logged = false
    end
    local pos = e.anim:Montage_GetPosition(m)
    local rate = e.anim:Montage_GetPlayRate(m) * (tonumber(m.RateScale) or 1)
    if rate < 0.01 then rate = 0.01 end
    local mt = montageTimeToHit(info, pos)
    if not mt then return nil end
    return mt / rate - (Config.Latency or 0), info
end

local function update()
    local pawn = player()
    -- "every block is perfect" mode: keep the window set on the current character (cheap check)
    if Config.Mode == "perfect" then
        if pawn and now() - (S.perfectAt or 0) > 0.5 then S.perfectAt = now() applyPerfect(pawn) end
    elseif next(Perfect.saved) then
        restorePerfect()
    end
    -- preview: once when the HUD appears, and all the time while the menu is open in bar mode
    if Config.Mode == "bar" and (now() < S.demoUntil or Menu.open) then
        local start = Menu.open and (S.menuDemoStart or now()) or S.demoStart
        local cycle = Config.LeadTime + 0.4
        draw(Config.LeadTime - (now() - start) % cycle)
        return
    end
    if Config.Mode ~= "bar" or not pawn then draw(nil) return end
    if now() - Creatures.scanAt > 30 then fullScan() end
    if now() - Creatures.nearAt > 0.5 then refreshNear(pawn) end
    local best, bestInfo
    for _, e in ipairs(Creatures.near) do
        local ok, tth, info = pcall(creatureTimeToHit, e)
        if ok and tth then
            local facing = threatens(e.char, pawn)
            if Config.Verbose and not e.logged then
                e.logged = true
                log("attack: %s, montage %s, %d hit(s), next hit in %.0f ms%s", className(e.char), info.name,
                    #info.hits, tth * 1000, facing and "" or " (not facing you - ignored)")
            end
            if facing and (not best or tth < best) then best, bestInfo = tth, info end
        end
    end
    S.best = best and { tth = best, name = bestInfo.name, at = now() } or nil
    if best and best <= Config.LeadTime then draw(best) else draw(nil) end
end

---------------------------------------------------------------------------
-- Hooks, loop and keys
---------------------------------------------------------------------------
local hooked = false
local function hookAll()
    if hooked then return true end
    local ok, err = pcall(function()
        NotifyOnNewObject("/Script/Maine.SurvivalCreature", function(obj) pcall(addCreature, obj) end)
    end)
    if not ok then return false, err end
    pcall(function()
        RegisterHook("/Script/Maine.BlockComponent:MulticastPlayBlockEffects", function(ctx, blockType)
            if not Config.Verbose then return end
            local bc = ctx:get()
            local pawn = player()
            local okO, owner = pcall(function() return bc:GetOwner() end)
            if not (okO and pawn and addr(owner) == addr(pawn)) then return end
            local t = tonumber(blockType:get()) or -1
            local names = { [1] = "normal block", [2] = "PERFECT block", [3] = "block break" }
            if Config.Mode ~= "bar" then
                log("%s (mode %s)", names[t] or tostring(t), Config.Mode)
            elseif S.best and now() - S.best.at < 0.3 then
                log("%s - predicted hit was %+.0f ms away (%s)", names[t] or tostring(t), S.best.tth * 1000, S.best.name)
            else
                log("%s - no attack was being tracked", names[t] or tostring(t))
            end
        end)
    end)
    hooked = true
    return true
end

local function loadedMessage()
    log("v%s loaded - mode %s, menu %s, language %s, settings %s", VERSION, Config.Mode, Config.MenuKey, LANG,
        SETTINGS_FILE)
end
if hookAll() then loadedMessage() end

local busy = false
LoopAsync(Config.LoopMs, function()
    if busy then return false end
    busy = true
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if not hooked then
                if not hookAll() then return end
                loadedMessage()
            end
            if not UI.built or now() - (UI.checkedAt or 0) > 1 then
                UI.checkedAt = now()
                if not UI.built or not stillAttached() then
                    UI.built = false
                    pcall(build)
                end
            end
            update()
        end)
        if not ok then log("error: %s", tostring(err)) end
        busy = false
    end)
    return false
end)

local function onKey(fn)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("error: %s", tostring(err)) end
        end)
    end
end

local menuKey = Key[Config.MenuKey] or Key.F6
RegisterKeyBind(menuKey, onKey(function()
    S.menuDemoStart = now()
    Menu.toggle()
end))
RegisterKeyBind(Key.UP_ARROW, onKey(function() Menu.move(-1) end))
RegisterKeyBind(Key.DOWN_ARROW, onKey(function() Menu.move(1) end))
RegisterKeyBind(Key.LEFT_ARROW, onKey(function() Menu.change(-1) end))
RegisterKeyBind(Key.RIGHT_ARROW, onKey(function() Menu.change(1) end))

log("v%s starting", VERSION)
