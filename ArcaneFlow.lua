-- ArcaneRuptureLite – Turtle WoW 1.12 (new, aura‑driven arcane script)
-- One‑button macro: /arcnew
-- Behavior (requested):
--   • Start by casting Arcane Rupture (to gain the Arcane Rupture aura).
--   • While the aura is ACTIVE → only cast Arcane Missiles (don’t clip channels).
--   • If the aura is MISSING → try, in order: Arcane Rupture → Arcane Surge → Fire Blast → Arcane Missiles.
--   • When Arcane Missiles is channeling, DO NOT interrupt unless the aura is missing and you can cast Arcane Rupture or Arcane Surge (these two may break the channel).
--   • After casting Surge, the next pulses will retry Arcane Rupture first (then fallbacks again if needed).
--
-- Notes:
--   • Reuses robust, castbar‑driven channel detection (UnitChannelInfo/pfUI/Blizzard castbar).
--   • Uses tooltip scanning for aura detection (works on Turtle 1.12 where UnitBuff returns textures only).
--   • Minimal state; no timers. Pulse this script via the /arcnew macro (bind to a key or spam as normal).

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
local UnitXP              = UnitXP -- optional DLL (Theo targeting helper, if present)
local UIParent            = UIParent
local strfind             = string.find
local BOOK                = BOOKTYPE_SPELL or "spell"

-- ===== Spells =====
local SPELL_SURGE     = "Arcane Surge"
local SPELL_RUPTURE   = "Arcane Rupture"
local SPELL_MISSILES  = "Arcane Missiles"
local SPELL_FIREBLAST = "Fire Blast"

-- ===== Utils =====
local function msg(txt)
  DEFAULT_CHAT_FRAME:AddMessage("|cff7ab0ff[ArcaneRuptureLite]|r " .. txt)
end

-- Find the HIGHEST‑RANK index for a spell name in the spellbook (1.12 API)
local spellIndexCache = {}
local function FindHighestRankIndexByName(name)
  local cached = spellIndexCache[name]
  if cached ~= nil then return cached end
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

-- ===== Aura detection (tooltip scan over player buffs/debuffs) =====
local function HasAura(name)
  for i = 1, 40 do
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    GameTooltip:ClearLines()
    GameTooltip:SetUnitBuff("player", i)
    local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
    if text and strfind(text, name, 1, true) then return true end
  end
  for i = 1, 40 do
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    GameTooltip:ClearLines()
    GameTooltip:SetUnitDebuff("player", i)
    local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
    if text and strfind(text, name, 1, true) then return true end
  end
  return false
end

-- ===== Channel detection (castbar‑driven, robust) =====
local function IsMissilesChanneling()
  -- Prefer native channel API when available
  if type(UnitChannelInfo) == "function" then
    local name = UnitChannelInfo("player")
    if name == SPELL_MISSILES then return true end
  end
  -- pfUI castbar
  local ok, pf = pcall(function() return pfUI and pfUI.castbar and pfUI.castbar.player end)
  if ok and pf then
    local sn = pf.spellname or (pf.label and pf.label.GetText and pf.label:GetText()) or nil
    if pf.channeling and sn == SPELL_MISSILES then return true end
  end
  -- Blizzard castbar fallback (can’t confirm name here; we assume our own channel)
  if CastingBarFrame and (CastingBarFrame.channeling or CastingBarFrame.mode == "channel") then
    return true
  end
  return false
end

-- ===== Casting helper =====
local function CastNow(name)
  EnsureHostileTarget()
  local idx = FindHighestRankIndexByName(name)
  if idx then CastSpell(idx, BOOK) else CastSpellByName(name) end
end

-- ===== Core pulse =====
function ArcaneRuptureLite_Pulse()
  -- If we are channeling Missiles, do nothing unless we’re allowed to Surge (exception)
  if IsMissilesChanneling() then
    -- While channeling: only break if the aura is missing and we can Rupture or Surge
    if not HasAura(SPELL_RUPTURE) then
      local canRupture = CanCast(SPELL_RUPTURE)
      local canSurge   = CanCast(SPELL_SURGE)
      if canRupture or canSurge then
        SpellStopCasting()
        if canRupture then
          CastNow(SPELL_RUPTURE)
        else
          CastNow(SPELL_SURGE)
        end
      end
    end
    return
  end

  -- Aura present → only cast Missiles
  if HasAura(SPELL_RUPTURE) then
    if CanCast(SPELL_MISSILES) then CastNow(SPELL_MISSILES) end
    return
  end

  -- Aura missing → Rupture → Surge → Fire Blast → Missiles (then wait)
  if CanCast(SPELL_RUPTURE) then CastNow(SPELL_RUPTURE); return end
  if CanCast(SPELL_SURGE)   then CastNow(SPELL_SURGE);   return end
  if CanCast(SPELL_FIREBLAST) then CastNow(SPELL_FIREBLAST); return end
  if CanCast(SPELL_MISSILES)  then CastNow(SPELL_MISSILES);  return end
end

-- ===== Slash command =====
SLASH_ARCNEW1 = "/arcnew"
SlashCmdList["ARCNEW"] = ArcaneRuptureLite_Pulse

msg("Loaded. Use /arcnew for aura‑driven rotation (Rupture → Missiles; fallbacks when aura is missing).")
