-- ArcaneFlow - Turtle WoW 1.12
-- One-button macro: /arcane
-- Perfect Rotation toggle: /arcaneflow
-- Surge gating toggle (global): /surgefree
-- Surge gating bypass only for PR: /prsurgefree
--
-- Perfect Rotation spec (final):
--   Rupture → Missiles → Missiles → (RESTART with Rupture)
--   At restart: if Rupture not ready → Surge; if Surge also not ready → Fire Blast (micro-filler) → else wait.
--   Never add extra Missiles after the 2 fillers.
--   PoM-before-Rupture only if AP/MQ are NOT up.
--   Never interrupt channels in PR, EXCEPT:
--     • If moving, cancel and fall through to instants (Surge → Fire Blast), reset rotation.
--     • If Rupture aura falls off mid–Missiles and Surge is ready, cancel and Surge immediately; treat as end of rotation.
--
-- New in this revision:
--   • **Castbar-driven channel tracking** (no fixed timers). We watch UnitChannelInfo/pfUI/Blizzard castbar
--     continuously and count Missiles completions on real channel end. This eliminates haste/timing pauses.

-- ===== Mode toggles =====
ArcaneFlow_SurgeUninhibited     = false -- /surgefree (global)
ArcaneFlow_PerfectRotation      = false -- /arcaneflow
ArcaneFlow_PR_SurgeBypassGating = false -- /prsurgefree (let Surge cast in PR even if AP/MQ are up)

-- ===== Fast locals =====
local SpellStopCasting    = SpellStopCasting
local UnitExists          = UnitExists
local UnitIsEnemy         = UnitIsEnemy
local CastSpellByName     = CastSpellByName
local CastSpell           = CastSpell
local DEFAULT_CHAT_FRAME  = DEFAULT_CHAT_FRAME
local GetSpellName        = GetSpellName
local GetSpellCooldown    = GetSpellCooldown
local GetTime             = GetTime
local CreateFrame         = CreateFrame
local IsUsableSpell       = IsUsableSpell
local UnitXP              = UnitXP -- optional DLL
local UIParent            = UIParent
local strlower, strfind   = string.lower, string.find
local BOOK                = BOOKTYPE_SPELL or "spell"

-- ===== Spells =====
local SPELL_SURGE     = "Arcane Surge"
local SPELL_RUPTURE   = "Arcane Rupture"
local SPELL_MISSILES  = "Arcane Missiles"
local SPELL_POM       = "Presence of Mind"
local SPELL_FIREBLAST = "Fire Blast"

-- ===== Utils =====
local function msg(txt)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7ab0ff[ArcaneFlow]|r " .. txt)
end

-- Find the HIGHEST-RANK index for a spell name in the spellbook (1.12 API)
local spellIndexCache = {}
local function FindHighestRankIndexByName(name)
    local cached = spellIndexCache[name]
    if cached then return cached end
    local i, last = 1, nil
    while true do
        local sName = GetSpellName(i, BOOK)
        if not sName then break end
        if sName == name then last = i end
        i = i + 1
    end
    spellIndexCache[name] = last
    return last
end

local function CooldownReady(name)
    local idx = FindHighestRankIndexByName(name)
    if not idx then return true end
    local start, duration, enabled = GetSpellCooldown(idx, BOOK)
    if enabled == 0 then return false end
    if not start or not duration or start == 0 or duration == 0 then return true end
    return (start + duration - GetTime()) <= 0
end

local function Usable(name)
    if IsUsableSpell then
        local usable, nomana = IsUsableSpell(name)
        return (usable and not nomana) or false
    end
    return true
end

local function CanCast(name)
    return Usable(name) and CooldownReady(name)
end

local function EnsureHostileTarget()
    if not UnitExists("target") or not UnitIsEnemy("player", "target") then
        if type(UnitXP) == "function" then UnitXP("target", "nearestEnemy") end
    end
end

-- ===== Aura detection (buffs & debuffs) =====
local function TheoDPS_HasAura(name)
    for i = 1, 40 do
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:ClearLines()
        GameTooltip:SetUnitBuff("player", i)
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if text and string.find(text, name, 1, true) then return true end
    end
    for i = 1, 40 do
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:ClearLines()
        GameTooltip:SetUnitDebuff("player", i)
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if text and string.find(text, name, 1, true) then return true end
    end
    return false
end

local function TheoDPS_SurgeAllowed()
    if ArcaneFlow_SurgeUninhibited then return true end
    return not TheoDPS_HasAura("Mind Quickening") and not TheoDPS_HasAura("Arcane Power")
end

-- ===== Channel detection (castbar-driven) =====
local function IsMissilesChanneling()
    if type(UnitChannelInfo) == "function" then
        local name = UnitChannelInfo("player")
        if name == SPELL_MISSILES then return true end
    end
    local ok, pf = pcall(function() return pfUI and pfUI.castbar and pfUI.castbar.player end)
    if ok and pf then
        local sn = pf.spellname or (pf.label and pf.label.GetText and pf.label:GetText()) or nil
        if pf.channeling and sn == SPELL_MISSILES then return true end
    end
    if CastingBarFrame and (CastingBarFrame.channeling or CastingBarFrame.mode == "channel") then
        -- Can't confirm spell name here; assume it's ours due to our own logic
        return true
    end
    return false
end

-- ===== Movement detection =====
local moving = false
local _lastMoveCheck = 0
local _lastX, _lastY = nil, nil

local function SoftIsMoving()
    if type(GetUnitSpeed) == "function" then
        local s = GetUnitSpeed("player")
        return (s or 0) > 0
    end
    if type(GetPlayerMapPosition) == "function" then
        if type(SetMapToCurrentZone) == "function" then SetMapToCurrentZone() end
        local x, y = GetPlayerMapPosition("player")
        if x and y then
            if _lastX then
                local dx = x - _lastX; local dy = y - _lastY
                if (dx*dx + dy*dy) > 0 then _lastX, _lastY = x, y; return true end
            end
            _lastX, _lastY = x, y
        end
    end
    return false
end

local moveFrame = CreateFrame("Frame")
moveFrame:SetScript("OnUpdate", function()
    local t = GetTime()
    if t - _lastMoveCheck > 0.10 then
        moving = SoftIsMoving()
        _lastMoveCheck = t
    end
end)

-- ===== PR STATE MACHINE =====
-- pr_state meanings:
--   0 = need Rupture (start of cycle)
--   1 = Missiles #1 completed
--   2 = Missiles #2 completed (RESTART point → try Rupture)
local pr_state = 0
local afterRupture = false -- prevents double Rupture; true right after Rupture completes until we start Missiles

-- Robust Missiles completion accounting (castbar-driven)
local chanMissiles     = false
local wantMissiles     = false
local missilesPending  = false   -- we issued Missiles and are waiting for real channel start/stop
local skipMissilesComplete = false -- set true when we cancel/interrupt so the next stop doesn’t count

local pendingRupture   = false

local function BeginMissiles()
    wantMissiles        = true
    missilesPending     = true
end

local function ClearMissilesFlags()
    missilesPending     = false
    chanMissiles        = false
    wantMissiles        = false
end

local function MarkMissilesCompleted()
    ClearMissilesFlags()
    afterRupture = false
    if pr_state < 2 then pr_state = pr_state + 1 end
end

local function CastNow(name)
    EnsureHostileTarget()
    local idx = FindHighestRankIndexByName(name)
    if idx then CastSpell(idx, BOOK) else CastSpellByName(name) end
    if name == SPELL_MISSILES then
        BeginMissiles()
    elseif name == SPELL_RUPTURE then
        pendingRupture = true
    end
end

-- ===== Events =====
local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
f:RegisterEvent("CHAT_MSG_SPELL_SELF_MISSES")
f:RegisterEvent("SPELLCAST_CHANNEL_START")
f:RegisterEvent("SPELLCAST_CHANNEL_STOP")
f:RegisterEvent("SPELLCAST_START")
f:RegisterEvent("SPELLCAST_STOP")
f:RegisterEvent("SPELLCAST_FAILED")
f:RegisterEvent("SPELLCAST_INTERRUPTED")

local surgeArmedUntil = 0
local ARM_WINDOW = 6.0

f:SetScript("OnEvent", function()
    local e = event
    if e == "CHAT_MSG_SPELL_SELF_DAMAGE" or e == "CHAT_MSG_SPELL_SELF_MISSES" then
        if not ArcaneFlow_PerfectRotation then
            local m = arg1
            if type(m) == "string" and m ~= "" then
                local lm = strlower(m)
                if strfind(lm, "your ", 1, true) and strfind(lm, "resist", 1, true) then
                    surgeArmedUntil = GetTime() + ARM_WINDOW
                end
            end
        end
        return
    end

    if e == "SPELLCAST_CHANNEL_START" or e == "SPELLCAST_START" then
        if wantMissiles then
            chanMissiles = true
            wantMissiles = false
        end
        return
    end

    if e == "SPELLCAST_CHANNEL_STOP" then
        if chanMissiles or missilesPending then
            if skipMissilesComplete then
                skipMissilesComplete = false
                ClearMissilesFlags()
            else
                MarkMissilesCompleted()
            end
        end
        return
    end

    if e == "SPELLCAST_INTERRUPTED" then
        if chanMissiles or missilesPending then
            skipMissilesComplete = true
            ClearMissilesFlags()
            -- reset rotation on interruption
            pr_state = 0; afterRupture = false
        end
        return
    end

    if e == "SPELLCAST_STOP" or e == "SPELLCAST_FAILED" then
        if pendingRupture then
            if e == "SPELLCAST_STOP" then
                -- Rupture successfully completed → begin Missiles stage next
                afterRupture = true
                pr_state = 0 -- zero missiles done so far
            end
            pendingRupture = false
        end
        -- Missiles FAILED: clear flags (no state advance)
        if e == "SPELLCAST_FAILED" and (chanMissiles or missilesPending) then
            skipMissilesComplete = true
            ClearMissilesFlags()
        end
        return
    end
end)

-- Extra: castbar-driven monitor to catch channel end even if no STOP fires
local lastChan = false
local mon = CreateFrame("Frame")
mon:SetScript("OnUpdate", function()
    local isChan = IsMissilesChanneling()
    if isChan and not lastChan then
        -- started (may not always see START)
        chanMissiles = true
        missilesPending = false
    elseif (not isChan) and lastChan then
        -- ended (treat as completion unless we purposely cancelled)
        if skipMissilesComplete then
            skipMissilesComplete = false
            ClearMissilesFlags()
        elseif chanMissiles then
            MarkMissilesCompleted()
        end
    end
    lastChan = isChan
end)

-- ===== PERFECT ROTATION PULSE =====
local function ArcaneFlow_PulsePerfect()
    local now = GetTime()

    -- While channeling Missiles: only narrow exceptions apply
    if IsMissilesChanneling() or chanMissiles then
        -- Movement: cancel channel, reset, and use instants
        if moving then
            skipMissilesComplete = true
            SpellStopCasting()
            ClearMissilesFlags()
            pr_state = 0; afterRupture = false
            if (ArcaneFlow_PR_SurgeBypassGating or TheoDPS_SurgeAllowed()) and CanCast(SPELL_SURGE) then CastNow(SPELL_SURGE); return end
            if CanCast(SPELL_FIREBLAST) then CastNow(SPELL_FIREBLAST); return end
            return
        end
        -- Rupture aura dropped mid-channel → Surge immediately (end of rotation, park at restart)
        if (not TheoDPS_HasAura(SPELL_RUPTURE)) and (ArcaneFlow_PR_SurgeBypassGating or TheoDPS_SurgeAllowed()) and CanCast(SPELL_SURGE) then
            skipMissilesComplete = true
            SpellStopCasting()
            ClearMissilesFlags()
            CastNow(SPELL_SURGE)
            pr_state = 2 -- park at restart; Rupture next
            return
        end
        -- Otherwise, don't clip
        return
    end

    -- Movement-aware: while moving but not channeling, prefer instants and reset rotation
    if moving then
        pr_state = 0; afterRupture = false
        if (ArcaneFlow_PR_SurgeBypassGating or TheoDPS_SurgeAllowed()) and CanCast(SPELL_SURGE) then CastNow(SPELL_SURGE); return end
        if CanCast(SPELL_FIREBLAST) then CastNow(SPELL_FIREBLAST); return end
        return
    end

    -- Restart point: try Rupture → Surge → Fire Blast → wait
    if pr_state >= 2 then
        if CanCast(SPELL_RUPTURE) then
            if not (TheoDPS_HasAura("Arcane Power") or TheoDPS_HasAura("Mind Quickening")) and CanCast(SPELL_POM) then CastNow(SPELL_POM); return end
            CastNow(SPELL_RUPTURE)
            return
        end
        if (ArcaneFlow_PR_SurgeBypassGating or TheoDPS_SurgeAllowed()) and CanCast(SPELL_SURGE) then CastNow(SPELL_SURGE); return end
        if CanCast(SPELL_FIREBLAST) then CastNow(SPELL_FIREBLAST); return end
        return
    end

    -- Build up exactly two Missiles between Ruptures
    if pr_state < 2 then
        -- Start of cycle: Rupture first, but only if we haven't just finished one
        if pr_state == 0 and (not afterRupture) and CanCast(SPELL_RUPTURE) then
            if not (TheoDPS_HasAura("Arcane Power") or TheoDPS_HasAura("Mind Quickening")) and CanCast(SPELL_POM) then CastNow(SPELL_POM); return end
            CastNow(SPELL_RUPTURE)
            return
        end
        -- Otherwise cast Missiles to progress to 1 then 2
        if CanCast(SPELL_MISSILES) then
            afterRupture = false
            CastNow(SPELL_MISSILES)
            return
        end
        -- Tiny fall-through to avoid idle if Missiles not immediately castable
        if CanCast(SPELL_FIREBLAST) then CastNow(SPELL_FIREBLAST); return end
        return
    end
end

-- ===== DEFAULT PULSE (legacy behavior when PR is OFF) =====
function ArcaneFlow_Pulse()
    if ArcaneFlow_PerfectRotation then
        return ArcaneFlow_PulsePerfect()
    end

    local now = GetTime()

    -- legacy: cast Rupture if aura missing; otherwise Missiles; Surge on resist-armed
    if now < surgeArmedUntil and TheoDPS_SurgeAllowed() and CanCast(SPELL_SURGE) then
        SpellStopCasting()
        CastNow(SPELL_SURGE)
        surgeArmedUntil = 0
        return
    end

    if not TheoDPS_HasAura(SPELL_RUPTURE) and CanCast(SPELL_RUPTURE) then
        CastNow(SPELL_RUPTURE)
        return
    end

    if CanCast(SPELL_MISSILES) then
        CastNow(SPELL_MISSILES)
        return
    end
end

-- ===== SLASH COMMANDS =====
SLASH_ARCANEFLOW1 = "/arcane"
SlashCmdList["ARCANEFLOW"] = ArcaneFlow_Pulse

SLASH_ARCANEFLOWMODE1 = "/arcaneflow"
SlashCmdList["ARCANEFLOWMODE"] = function()
    ArcaneFlow_PerfectRotation = not ArcaneFlow_PerfectRotation
    local state = ArcaneFlow_PerfectRotation and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cff7ab0ff[ArcaneFlow]|r Perfect Rotation mode: " .. state)
    if ArcaneFlow_PerfectRotation then
        DEFAULT_CHAT_FRAME:AddMessage("|cff7ab0ff[ArcaneFlow]|r PR: Rupture → Missiles ×2 → (Rupture restart). Fallbacks: Surge → Fire Blast → wait. Castbar-driven channels.")
    end
end

SLASH_SURGEFREE1 = "/surgefree"
SlashCmdList["SURGEFREE"] = function()
    ArcaneFlow_SurgeUninhibited = not ArcaneFlow_SurgeUninhibited
    local state = ArcaneFlow_SurgeUninhibited and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cff7ab0ff[ArcaneFlow]|r Surge Uninhibited (global): " .. state)
end

SLASH_PRSURGEFREE1 = "/prsurgefree"
SlashCmdList["PRSURGEFREE"] = function()
    ArcaneFlow_PR_SurgeBypassGating = not ArcaneFlow_PR_SurgeBypassGating
    local state = ArcaneFlow_PR_SurgeBypassGating and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cff7ab0ff[ArcaneFlow]|r PR Surge Bypass Gating: " .. state)
end

msg("Loaded. Use /arcane. Toggle Perfect Rotation with /arcaneflow.")

