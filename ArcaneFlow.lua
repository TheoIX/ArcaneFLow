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


-- ============================================================================
-- ArcanePrep.lua – Consumable/Trinket/Spell prep macro
-- One‑button macro: /arcprep
-- Order:
--   1) If missing buff "Potion of Quickness" → use item "Potion of Quickness" from bags.
--   2) If missing buff "Juju Flurry" → temporarily target self, use item "Juju Flurry", then restore target.
--   3) Use trinket in inventory slot 13 (upper trinket).
--   4) Lastly, cast Arcane Power (if off CD).
-- Each press performs the FIRST available action in this list and returns (to respect GCD).

local function PP_msg(txt)
  DEFAULT_CHAT_FRAME:AddMessage("|cff7ab0ff[ArcPrep]|r " .. txt)
end

-- Tooltip‑based buff check (substring match of buff name)
local function HasPlayerBuff(name, exact)
  for i = 1, 40 do
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    GameTooltip:ClearLines()
    GameTooltip:SetUnitBuff("player", i)
    local t = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
    if t then
      if exact then
        if t == name then return true end
      else
        if string.find(t, name, 1, true) then return true end
      end
    end
  end
  return false
end

-- Bag scan + use item by (partial) name; honors item cooldown
local function UseBagItemByName(name)
  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag)
    if slots then
      for slot = 1, slots do
        local link = GetContainerItemLink(bag, slot)
        if link and string.find(link, name, 1, true) then
          local start, duration, enable = GetContainerItemCooldown(bag, slot)
          if enable ~= 0 and (not start or duration == 0 or (start + duration - GetTime()) <= 0) then
            UseContainerItem(bag, slot)
            return true
          end
        end
      end
    end
  end
  return false
end

-- Trinket use helper (13 = upper trinket)
local function UseTrinket(slot)
  local start, duration, enable = GetInventoryItemCooldown("player", slot)
  if enable == 0 then return false end
  if not start or duration == 0 or (start + duration - GetTime()) <= 0 then
    UseInventoryItem(slot)
    return true
  end
  return false
end

-- Spell cast helper (no ranks)
local function CastIfReady(spell)
  local idx
  for i = 1, 300 do
    local n = GetSpellName(i, BOOKTYPE_SPELL or "spell")
    if not n then break end
    if n == spell then idx = i end
  end
  if not idx then return false end
  local start, duration, enabled = GetSpellCooldown(idx, BOOKTYPE_SPELL or "spell")
  if enabled == 0 then return false end
  if not start or duration == 0 or (start + duration - GetTime()) <= 0 then
    CastSpell(idx, BOOKTYPE_SPELL or "spell")
    return true
  end
  return false
end

-- Target self temporarily and run an action, then restore prior target
local function DoOnSelf(action)
  local hadTarget = UnitExists("target")
  local prevName = hadTarget and UnitName("target") or nil

  -- Try Blizzard self-target first
  TargetUnit("player")

  -- Fallback: explicit self by name (mirrors /target <playerName>)
  local me = UnitName("player")
  local cur = UnitName("target")
  if me and (not cur or cur ~= me) then
    TargetByName(me, true)
  end

  local ok = action()

  if hadTarget and prevName then
    TargetByName(prevName, true)
  else
    ClearTarget()
  end
  return ok
end

function ArcPrep_Pulse()
  -- 1) Potion of Quickness buff → ensure present
  if not HasPlayerBuff("Potion of Quickness") then
    if UseBagItemByName("Potion of Quickness") then
      PP_msg("Using Potion of Quickness")
      return
    end
  end

  -- 2) Juju Flurry buff → ensure present (target self before using)
  if not HasPlayerBuff("Juju Flurry") then
    local ok = DoOnSelf(function()
      return UseBagItemByName("Juju Flurry")
    end)
    if ok then
      PP_msg("Using Juju Flurry")
      return
    end
  end

  -- 3) Use trinket in slot 13 (only if Mind Quickening buff not already active)
  if not HasPlayerBuff("Mind Quickening") then
    if UseTrinket(13) then
      PP_msg("Activating Trinket (slot 13)")
      return
    end
  end

  -- 4) Cast Arcane Power (only if AP buff not already active)
  if not HasPlayerBuff("Arcane Power", true) then
    if CastIfReady("Arcane Power") then
      PP_msg("Casting Arcane Power")
      return
    end
  end

  -- Nothing done
  PP_msg("Nothing to do (all buffs/cooldowns busy)")
end

SLASH_ARCPREP1 = "/arcprep"
SlashCmdList["ARCPREP"] = ArcPrep_Pulse
PP_msg("Loaded. Use /arcprep to apply Quickness → Flurry → Trinket13 → Arcane Power (first available per press).")

