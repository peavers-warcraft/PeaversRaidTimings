--------------------------------------------------------------------------------
-- Spell resolution
--
-- The data addon ships spell IDs and nothing else: names and icons are resolved
-- here, at runtime, from the client. That keeps the payload small and makes every
-- string correct in the player's locale for free. Both lookups are feature-detected
-- and pcall-guarded — a spell that no longer exists must degrade to a readable
-- placeholder, never break the announcer or the list.
--------------------------------------------------------------------------------

local _, PRT = ...

local Spells = {}
PRT.Spells = Spells

local FALLBACK_ICON = 134400 -- Interface\Icons\INV_Misc_QuestionMark

local nameCache = {}
local iconCache = {}

---Localized spell name for a spell ID, or a readable placeholder.
---@param spellID number
---@return string name
function Spells:GetName(spellID)
	if type(spellID) ~= "number" then return "?" end

	local cached = nameCache[spellID]
	if cached then return cached end

	local name
	if C_Spell and type(C_Spell.GetSpellName) == "function" then
		local ok, result = pcall(C_Spell.GetSpellName, spellID)
		if ok and type(result) == "string" and result ~= "" then
			name = result
		end
	end

	-- Only cache real answers. A miss can mean the spell data simply hasn't
	-- streamed in yet, and caching that would make the placeholder permanent.
	if name then
		nameCache[spellID] = name
		return name
	end
	return "Spell " .. tostring(spellID)
end

---Icon texture ID for a spell ID, falling back to the question mark.
---@param spellID number
---@return number textureID
function Spells:GetIcon(spellID)
	if type(spellID) ~= "number" then return FALLBACK_ICON end

	local cached = iconCache[spellID]
	if cached then return cached end

	if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
		local ok, result = pcall(C_Spell.GetSpellTexture, spellID)
		if ok and type(result) == "number" then
			iconCache[spellID] = result
			return result
		end
	end

	return FALLBACK_ICON
end

---Drops the caches. Called on locale/spec churn; cheap enough to call freely.
function Spells:ClearCache()
	nameCache = {}
	iconCache = {}
end
