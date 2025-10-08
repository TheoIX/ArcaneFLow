-- ArcaneFlow - Turtle WoW 1.12
-- One-button macro: /arcane
-- Behavior:
--   • After ANY of your spells is resisted, Arcane Surge will fire on the NEXT press (within a short window) if castable.
--   • Surge gating: It will NOT cast while "Mind Quickening" or "Arcane Power" are active on you.
--   • Otherwise: Arcane Rupture > Arcane Missiles (one spell per press).
--   • No 4.8s timer gate; Arcane Missiles simply won't recast while a channel is active (anti-clip only).
--   • While channeling Missiles, spamming the macro will NOT clip it; only Arcane Surge or Arcane Rupture (if its aura is missing) may preempt it.
-- Targeting:
--   • Uses UnitXP("target", "nearestEnemy") from the unitxp DLL to acquire a hostile target.
-- Buff logic:
--   • Arcane Rupture will ONLY cast if the "Arcane Rupture" self-aura (buff or debuff) is NOT already active.

-- Surge Uninhibited mode (off by default)
ArcaneFlow_SurgeUninhibited = false

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
local UnitXP              = UnitXP -- provided by unitxp DLL
local strlower, strfind   = string.lower, string.find
local BOOK                = BOOKTYPE_SPELL or "spell"

-- ===== Aura check utility (buffs & debuffs) =====
local function TheoDPS_HasAura(name)
    -- Scan buffs first
    for i = 1, 40 do
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:ClearLines()
        GameTooltip:SetUnitBuff("player", i)
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if text and string.find(text, name, 1, true) then
            return true
        end
    end
    -- Then scan debuffs
    for i = 1, 40 do
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:ClearLines()
        GameTooltip:SetUnitDebuff("player", i)
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if text and string.find(text, name, 1, true) then
            return true
        end
    end
    return false
end

-- ===== Surge gating (aura-based) =====
local function TheoDPS_SurgeAllowed()
    -- When Surge Uninhibited mode is ON, never inhibit Arcane Surge.
    if ArcaneFlow_SurgeUninhibited then
        return true
    end
    return not TheoDPS_HasAura("Mind Quickening") and not TheoDPS_HasAura("Arcane Power")
end

-- ===== Spells =====
local SPELL_SURGE    = "Arcane Surge"
local SPELL_RUPTURE  = "Arcane Rupture"
local SPELL_MISSILES = "Arcane Missiles"


-- ===== Channel detection (multi-source) =====
local function IsMissilesChanneling()
    -- Prefer SuperWoW/TBC-style API if present
    if type(UnitChannelInfo) == "function" then
        local name, _, _, _, startTime, endTime = UnitChannelInfo("player")
        if name == SPELL_MISSILES then
            if endTime then missilesChannelUntil = (endTime / 1000) end
            return true
        end
    end
    -- pfUI castbar (best-effort; structure may vary by version)
    local ok, pf = pcall(function() return pfUI and pfUI.castbar and pfUI.castbar.player end)
    if ok and pf then
        local sn = pf.spellname or (pf.label and pf.label.GetText and pf.label:GetText()) or nil
        if pf.channeling and sn == SPELL_MISSILES then
            return true
        end
    end
    -- Blizzard casting bar fallback
    if CastingBarFrame and (CastingBarFrame.channeling or CastingBarFrame.mode == "channel") then
        -- Can\'t confirm spell name here, but our own logic only channels Missiles
        return true
    end
    return false
end

-- ===== Util =====
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
    if not idx then return true end -- if not found, don't block
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

-- Generic readiness for any spell
local function CanCast(name)
    return Usable(name) and CooldownReady(name)
end

-- Use unitxp DLL to ensure we have a hostile target
local function EnsureHostileTarget()
    if not UnitExists("target") or not UnitIsEnemy("player", "target") then
        -- Replace default targeting with unitxp DLL call
        UnitXP("target", "nearestEnemy")
    end
end

-- ===== Missiles gating & channel state =====
local chanMissiles   = false       -- true while Missiles is actively channeling
local wantMissiles   = false       -- set when we attempt to cast Missiles, cleared on start
local missilesLocked = false       -- soft lock until channel events say we're done
local missilesLockUntil = 0        -- hard lock timeout (failsafe)
local missilesGatePending = 0      -- timestamp when we tried to start Missiles; gate applies only if channel actually starts
local missilesChannelUntil = 0     -- absolute time when Missiles channel should naturally end (anti-clip guard)

        -- hard lock timeout (failsafe)

local function CastNow(name)
    EnsureHostileTarget()
    local idx = FindHighestRankIndexByName(name)
    if idx then
        CastSpell(idx, BOOK)
    else
        CastSpellByName(name)
    end
    if name == SPELL_MISSILES then
        wantMissiles      = true  -- expect a channel start next
        missilesLocked    = true  -- prevent re-casting / clipping until channel ends
        missilesLockUntil = GetTime() + 5.2 -- hard lock (approx channel length)
        missilesGatePending = GetTime() -- don't start the 4.8s gate until channel actually begins
    elseif name == SPELL_RUPTURE or name == SPELL_SURGE then
        -- no timer gate to reset
    end
end

-- ===== Resist -> Surge arming =====
local surgeArmedUntil = 0      -- timestamp; if > GetTime() then armed
local ARM_WINDOW = 6.0         -- seconds to keep the flag after a resist

local f = CreateFrame("Frame")
-- Combat log (your damage): partial & full resists
f:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
f:RegisterEvent("CHAT_MSG_SPELL_SELF_MISSES")
-- Channel tracking: mark when Missiles actually starts/ends channeling
f:RegisterEvent("SPELLCAST_CHANNEL_START")
f:RegisterEvent("SPELLCAST_START") -- some 1.12 cores fire START even for channels
f:RegisterEvent("SPELLCAST_CHANNEL_STOP")
f:RegisterEvent("SPELLCAST_STOP") -- observed on some cores; we won't unlock from this alone for channels
f:RegisterEvent("SPELLCAST_FAILED")

f:SetScript("OnEvent", function()
    local e = event -- 1.12 provides global 'event' and 'arg1'
    if e == "CHAT_MSG_SPELL_SELF_DAMAGE" or e == "CHAT_MSG_SPELL_SELF_MISSES" then
        local m = arg1
        if type(m) == "string" and m ~= "" then
            local lm = strlower(m)
            if strfind(lm, "your ", 1, true) and strfind(lm, "resist", 1, true) then
                surgeArmedUntil = GetTime() + ARM_WINDOW
            end
        end
        return
    end

    if e == "SPELLCAST_CHANNEL_START" or e == "SPELLCAST_START" then
        -- Only treat as Missiles channel if we *intended* to cast Missiles
        if wantMissiles then
            chanMissiles         = true
            missilesLocked       = true
            missilesLockUntil    = GetTime() + 5.2
            missilesGatePending  = 0
            missilesChannelUntil = GetTime() + 5.2          -- hard anti-clip timer; only Surge may preempt
        end
        wantMissiles = false
        return
    end

    if e == "SPELLCAST_CHANNEL_STOP" or e == "SPELLCAST_FAILED" then
        -- If Missiles failed to start (no channel) after we attempted it, cancel pending gate
        if (e == "SPELLCAST_FAILED" or not chanMissiles) and missilesGatePending > 0 then
            missilesGatePending = 0
        end
        chanMissiles         = false
        wantMissiles         = false
        missilesLocked       = false
        missilesLockUntil    = 0
        missilesChannelUntil = 0
        return
    end

    if e == "SPELLCAST_STOP" then
        -- Some cores fire STOP during channels too; do NOT unlock here unless we weren't channeling
        if not chanMissiles then
            wantMissiles         = false
            missilesLocked       = false
            missilesLockUntil    = 0
            missilesChannelUntil = 0
        end
        return
    end
end)

-- ===== Main pulse =====
function ArcaneFlow_Pulse()
    local now = GetTime()

    -- If we tried to start Missiles but no channel began shortly after, clear the soft lock and pending gate
    if missilesGatePending > 0 and (now - missilesGatePending) > 0.7 and not chanMissiles then
        missilesLocked = false
        wantMissiles = false
        missilesGatePending = 0
    end

    -- HARD anti-clip: if Missiles should still be channeling, do nothing (only Surge may preempt)
    if missilesChannelUntil > 0 and now < missilesChannelUntil then
        -- Allow Surge to preempt even during channel
        if now < surgeArmedUntil and TheoDPS_SurgeAllowed() and CanCast(SPELL_SURGE) then
            SpellStopCasting()
            CastNow(SPELL_SURGE)
            surgeArmedUntil = 0
            missilesLocked  = false
            chanMissiles    = false
            wantMissiles    = false
            return
        end
        -- Allow Rupture to preempt if its aura is missing and spell is castable
        if not TheoDPS_HasAura("Arcane Rupture") and CanCast(SPELL_RUPTURE) then
            SpellStopCasting()
            CastNow(SPELL_RUPTURE)
            missilesLocked  = false
            chanMissiles    = false
            wantMissiles    = false
            return
        end
        return
    end



    -- If a recent resist occurred, try Surge on THIS press when it's actually castable
    if now < surgeArmedUntil and TheoDPS_SurgeAllowed() and CanCast(SPELL_SURGE) then
        SpellStopCasting()
        CastNow(SPELL_SURGE)
        surgeArmedUntil = 0
        missilesLocked  = false
        chanMissiles    = false
        wantMissiles    = false
        return
    end

    -- If Missiles is channeling OR locked pending its channel start, do nothing (avoid clipping)
    if IsMissilesChanneling() or chanMissiles or missilesLocked or (CastingBarFrame and CastingBarFrame.channeling) then
        -- Preempt with Rupture if its aura dropped and it is castable
        if not TheoDPS_HasAura("Arcane Rupture") and CanCast(SPELL_RUPTURE) then
            SpellStopCasting()
            CastNow(SPELL_RUPTURE)
            missilesLocked  = false
            chanMissiles    = false
            wantMissiles    = false
            return
        end
        -- failsafe: clear stale lock after timeout
        if missilesLocked and now > missilesLockUntil then missilesLocked = false end
        return
    end

    -- Priority: Rupture (only if NOT already active), then (gated) Missiles
    if not TheoDPS_HasAura("Arcane Rupture") and CanCast(SPELL_RUPTURE) then
        CastNow(SPELL_RUPTURE)
        return
    end

    if CanCast(SPELL_MISSILES) then
        CastNow(SPELL_MISSILES)
        return
    end
end

-- Register slash command
SLASH_ARCANEFLOW1 = "/arcane"
SlashCmdList["ARCANEFLOW"] = ArcaneFlow_Pulse

msg("Loaded. Use |cffffff00/arcane|r in a macro.")

-- Independent toggle: Surge Uninhibited mode (not connected to /storm)
SLASH_SURGEFREE1 = "/surgefree"
SlashCmdList["SURGEFREE"] = function()
    ArcaneFlow_SurgeUninhibited = not ArcaneFlow_SurgeUninhibited
    local state = ArcaneFlow_SurgeUninhibited and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cff7ab0ff[ArcaneFlow]|r Surge Uninhibited mode: " .. state)
end

msg("Loaded. Use |cffffff00/arcane|r in a macro.")


