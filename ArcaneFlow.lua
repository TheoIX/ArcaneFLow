-- ArcaneFlow - Turtle WoW 1.12
-- One-button macro: /arcane
-- Behavior:
--   • After ANY of your spells is resisted, Arcane Surge will fire on the NEXT press (within a short window) if castable.
--   • Otherwise: Arcane Rupture > Arcane Missiles (one spell per press).
--   • Arcane Missiles can be cast at most once every 4.8s, unless Arcane Surge or Arcane Rupture are cast during that period, which resets the 4.8s gate.
--   • While channeling Missiles, spamming the macro will NOT clip it; only Arcane Surge may preempt it.

-- ===== Fast locals =====
local SpellStopCasting    = SpellStopCasting
local TargetNearestEnemy  = TargetNearestEnemy
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
local strlower, strfind   = string.lower, string.find
local BOOK                = BOOKTYPE_SPELL or "spell"

-- ===== Spells =====
local SPELL_SURGE    = "Arcane Surge"
local SPELL_RUPTURE  = "Arcane Rupture"
local SPELL_MISSILES = "Arcane Missiles"

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

local function EnsureHostileTarget()
    if not UnitExists("target") or not UnitIsEnemy("player", "target") then
        TargetNearestEnemy()
    end
end

-- ===== Missiles gating & channel state =====
local MISSILES_GATE = 4.8         -- seconds between allowed Missiles casts
local missilesNextOK = 0           -- time when Missiles is next allowed
local chanMissiles   = false       -- true while Missiles is actively channeling
local wantMissiles   = false       -- set when we attempt to cast Missiles, cleared on start
local missilesLocked = false       -- soft lock until channel events say we're done
local missilesLockUntil = 0        -- hard lock timeout (failsafe)

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
        missilesNextOK    = GetTime() + MISSILES_GATE
    elseif name == SPELL_RUPTURE or name == SPELL_SURGE then
        -- Reset the Missiles 4.8s gate immediately when Rupture/Surge are cast
        missilesNextOK = 0
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
f:RegisterEvent("SPELLCAST_STOP")
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
            chanMissiles      = true
            missilesLocked    = true
            missilesLockUntil = GetTime() + 5.2
        end
        wantMissiles = false
        return
    end

    if e == "SPELLCAST_CHANNEL_STOP" or e == "SPELLCAST_STOP" or e == "SPELLCAST_FAILED" then
        chanMissiles      = false
        wantMissiles      = false
        missilesLocked    = false
        missilesLockUntil = 0
        return
    end
end)

-- ===== Main pulse =====
function ArcaneFlow_Pulse()
    local now = GetTime()

    -- If a recent resist occurred, try Surge on THIS press when it's actually castable
    if now < surgeArmedUntil and CanCast(SPELL_SURGE) then
        SpellStopCasting()
        CastNow(SPELL_SURGE)
        surgeArmedUntil = 0
        missilesLocked  = false
        chanMissiles    = false
        wantMissiles    = false
        return
    end

    -- If Missiles is channeling OR locked pending its channel start, do nothing (avoid clipping)
    if chanMissiles or missilesLocked or (CastingBarFrame and CastingBarFrame.channeling) then
        -- failsafe: clear stale lock after timeout
        if missilesLocked and now > missilesLockUntil then missilesLocked = false end
        return
    end

    -- Priority: Rupture, then (gated) Missiles
    if CanCast(SPELL_RUPTURE) then
        CastNow(SPELL_RUPTURE)
        return
    end

    if now >= missilesNextOK and CanCast(SPELL_MISSILES) then
        CastNow(SPELL_MISSILES)
        return
    end
end

-- Register slash command
SLASH_ARCANEFLOW1 = "/arcane"
SlashCmdList["ARCANEFLOW"] = ArcaneFlow_Pulse

msg("Loaded. Use |cffffff00/arcane|r in a macro.")

