--------------------------------------------------------------------------------
-- CueList — the on-screen ghost
--
-- This is where the product becomes visible. Two things have to be on screen or
-- the addon is just a spell timer:
--
--   WHO YOU ARE FOLLOWING. The list is one named player's real run, so the
--   header carries their name, rank and score. Never render the casts without
--   the attribution — the timings are somebody's performance, not a fact.
--
--   HOW YOU ARE DOING AGAINST THEM. Every row you have matched shows a signed
--   delta: "-1.4s" green means you got there ahead of them, "+2.4s" orange means
--   behind. That is the racing-ghost feel and the reason to run this rather than
--   read a note.
--
-- Built on the PeaversCommons primitives rather than hand-rolled frames:
--   BarPool           rows are acquired/released as the cursor moves, so a
--                     10-minute fight creates one row per visible slot, not one
--                     per cast.
--   AnimatedStatusBar the row's fill.
--   UpdateCoordinator debounces the 10Hz encounter tick down to the redraw rate
--                     the display actually needs.
--
-- BarManager is the one primitive deliberately not used: it builds a fixed set of
-- bars from config-driven definitions, whereas this list's rows are re-keyed every
-- redraw as casts scroll past. BarPool is the pooling primitive underneath that
-- use case, so this goes straight to it.
--
-- Spell names and icons are resolved at RUNTIME through PRT.Spells — the data
-- addon ships spell IDs only, which keeps the payload small and every string
-- correct in the player's locale.
--
-- All frames are anonymous and held in locals (NS001). Nothing here needs a name:
-- no XML template, no Bindings.xml, no cross-addon integration point resolves
-- these by string.
--------------------------------------------------------------------------------

local _, PRT = ...

local PeaversCommons = _G.PeaversCommons

local CueList = {}
PRT.CueList = CueList

local ICON_SIZE = 18
local TITLE_HEIGHT = 14
local GHOST_HEIGHT = 14
local HEADER_HEIGHT = TITLE_HEIGHT + GHOST_HEIGHT
local PADDING = 4

-- What the frame says when nothing is running. The list must never be blank: a
-- frame with no backdrop and no text changes zero pixels when it is toggled, so a
-- new install's first `/prt` looks like an addon that does not work, and the drag
-- handle sits over a region nobody can see. There is always something to see and
-- something to read.
local RESTING_TITLE = "Peavers Raid Timings"
local RESTING_HINT = "|cff888888No encounter active - /prt test <encounterID> to preview|r"

---The row width, which is what `barWidth` means to the player.
local function ContentWidth()
	return PRT.Config.barWidth or 240
end

---The frame width. The backdrop's inset is ours, not theirs — widening the
---container keeps a row exactly `barWidth` wide with the border clear of it.
local function ContainerWidth()
	return ContentWidth() + PADDING * 2
end

-- How far ahead a bar starts filling. Wider than the lead-in so a cast is visible
-- before it starts warning.
local function FillWindow()
	return math.max((PRT.Config.leadInSeconds or 4) * 3, 12)
end

-- Populated by CueList:Initialize(). Declared without an initializer so the
-- language server infers each one's real type from the assignment there rather
-- than pinning it to nil.
local container
local titleText
local ghostText
local pool
local coordinator

local currentClock = 0

-- Set by a bare /prt that turned the list ON while nothing was running. It exists
-- so `hideOutOfEncounter` cannot immediately swallow the frame the player just
-- asked to look at. Session-only and deliberately not persisted: it records an
-- action, not a preference.
local previewOverride = false

--------------------------------------------------------------------------------
-- Row construction
--------------------------------------------------------------------------------

local function CreateRow(parent)
	local row = {}

	local width = PRT.Config.barWidth or 240
	local height = PRT.Config.barHeight or 24

	local frame = CreateFrame("Frame", nil, parent)
	frame:SetSize(width, height)
	row.frame = frame

	row.bar = PeaversCommons.AnimatedStatusBar:New(frame, {
		width = width - ICON_SIZE - PADDING,
		height = height,
		minValue = 0,
		maxValue = 100,
		animationDuration = 0.15,
	})
	row.bar:SetPoint("TOPLEFT", frame, "TOPLEFT", ICON_SIZE + PADDING, 0)

	row.icon = frame:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ICON_SIZE, ICON_SIZE)
	row.icon:SetPoint("LEFT", frame, "LEFT", 0, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.nameText:SetPoint("LEFT", row.bar:GetFrame(), "LEFT", 4, 0)
	row.nameText:SetJustifyH("LEFT")

	row.timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.timeText:SetPoint("RIGHT", row.bar:GetFrame(), "RIGHT", -4, 0)
	row.timeText:SetJustifyH("RIGHT")

	return row
end

local function ResetRow(row)
	if not row then return end
	row.frame:ClearAllPoints()
	row.frame:Hide()
	row.bar:SetValue(0, true)
	row.nameText:SetText("")
	row.timeText:SetText("")
end

--------------------------------------------------------------------------------
-- Row state
--------------------------------------------------------------------------------

-- r, g, b per state. Deliberately few states: the list is read at a glance,
-- mid-pull, by someone who is also playing.
local STATE_COLORS = {
	upcoming = { r = 0.30, g = 0.45, b = 0.65 },
	warning  = { r = 0.90, g = 0.70, b = 0.20 },
	current  = { r = 0.20, g = 0.80, b = 0.35 },
	hit      = { r = 0.20, g = 0.55, b = 0.30 },
	missed   = { r = 0.70, g = 0.25, b = 0.25 },
}

---`missed` is reachable because Timeline keeps an entry on screen for missGrace
---seconds, which is clamped strictly above activeWindow. Change one without the
---other and this state silently becomes dead code again.
local function StateFor(entry, remaining, timeline)
	if entry.hit then return "hit" end
	if timeline:IsMissed(entry, currentClock) then return "missed" end
	if remaining <= 0 then return "current" end
	if remaining <= (PRT.Config.leadInSeconds or 4) then return "warning" end
	return "upcoming"
end

local function FormatRemaining(remaining)
	if remaining <= 0 then return "now" end
	if remaining < 10 then return string.format("%.1f", remaining) end
	return PeaversCommons.Utils.FormatTime(remaining)
end

---Signed seconds against the ghost. Ahead reads green, behind reads orange —
---the sign is the information, so it is always printed.
---@param delta number
---@return string
local function FormatDelta(delta)
	if delta < 0 then
		return string.format("|cff55ff55%.1fs|r", delta)
	end
	return string.format("|cffffaa55+%.1fs|r", delta)
end

-- Geometry is reapplied on every redraw rather than baked in at construction.
-- Pooled rows outlive any settings change, so a row built at the old width would
-- otherwise stay that width until the pool was thrown away — and throwing it away
-- orphans the frames, which cannot be destroyed in WoW.
local function ApplyRowGeometry(row)
	local width = PRT.Config.barWidth or 240
	local height = PRT.Config.barHeight or 24

	row.frame:SetSize(width, height)
	row.bar:SetSize(width - ICON_SIZE - PADDING, height)
	row.icon:SetSize(ICON_SIZE, ICON_SIZE)
end

local function UpdateRow(row, entry, remaining, timeline)
	local state = StateFor(entry, remaining, timeline)
	local color = STATE_COLORS[state]

	ApplyRowGeometry(row)

	row.icon:SetTexture(PRT.Spells:GetIcon(entry.spell))
	row.nameText:SetText(PRT.Spells:GetName(entry.spell))

	-- Once you have made the cast, the countdown is history and the delta is the
	-- only number that still means anything.
	if entry.hit and entry.delta and PRT.Config.showDelta then
		row.timeText:SetText(FormatDelta(entry.delta))
	elseif entry.hit and PRT.Config.showHitMarkers then
		row.timeText:SetText("|cff55ff55v|r")
	elseif state == "missed" then
		row.timeText:SetText("|cffff5555missed|r")
	else
		row.timeText:SetText(FormatRemaining(remaining))
	end

	local window = FillWindow()
	local filled = math.min(math.max((window - remaining) / window, 0), 1) * 100
	-- No animation: the value is a function of the clock and is already updated
	-- every tick, so animating it just lags the countdown behind the audio.
	row.bar:SetValue(filled, true)
	row.bar:SetColor(color.r, color.g, color.b)

	row.frame:SetAlpha(1.0)
	row.frame:Show()
end

--------------------------------------------------------------------------------
-- Header
--------------------------------------------------------------------------------

---Who we are following, plus how the run is going against them. Rewritten every
---redraw because the running delta is live.
local function UpdateGhostLine(timeline)
	if not ghostText then return end

	if not PRT.Config.showGhostHeader then
		ghostText:SetText("")
		return
	end

	local label = PRT.DescribeGhost(PRT.Encounter and PRT.Encounter.ghost)
	if not label then
		ghostText:SetText("")
		return
	end

	local text = "|cff888888Following:|r " .. label

	if timeline and PRT.Config.showDelta then
		local matched, total, average = timeline:GetScore()
		if average then
			text = text .. string.format("  |cff888888%d/%d|r %s", matched, total,
				FormatDelta(average))
		end
	end

	ghostText:SetText(text)
end

--------------------------------------------------------------------------------
-- Redraw
--------------------------------------------------------------------------------

---The out-of-encounter card: the frame, its name, and how to get a preview out of
---it. Drawn instead of an empty rectangle whenever there is no timeline to show.
local function ShowRestingState()
	if titleText then titleText:SetText(RESTING_TITLE) end
	if ghostText then ghostText:SetText(RESTING_HINT) end
	if container then container:SetHeight(HEADER_HEIGHT + PADDING * 2) end
end

local function Redraw()
	if not container then return end

	local encounter = PRT.Encounter
	local timeline = encounter and encounter.timeline
	if not timeline then
		pool:ReleaseAll()
		ShowRestingState()
		return
	end

	UpdateGhostLine(timeline)

	local maxBars = PRT.Config.maxBars or 5
	local height = PRT.Config.barHeight or 24
	local spacing = PRT.Config.barSpacing or 2

	local visible = timeline:GetUpcoming(currentClock, maxBars)

	-- Release rows whose cast is no longer on screen before acquiring, so the pool
	-- reuses them in the same pass rather than growing.
	local wanted = {}
	for _, entry in ipairs(visible) do
		wanted[entry.index] = true
	end

	local stale = {}
	for key in pairs(pool:GetAllBars()) do
		if not wanted[key] then
			stale[#stale + 1] = key
		end
	end
	for _, key in ipairs(stale) do
		pool:Release(key)
	end

	local y = -(PADDING + HEADER_HEIGHT)
	for _, entry in ipairs(visible) do
		local row = pool:Acquire(container, nil, entry.index)
		row.frame:ClearAllPoints()
		row.frame:SetPoint("TOPLEFT", container, "TOPLEFT", PADDING, y)
		UpdateRow(row, entry, timeline:TimeUntil(entry, currentClock), timeline)
		y = y - (height + spacing)
	end

	-- With no rows this lands on exactly the resting height, so a fight whose casts
	-- have all scrolled past collapses to the header card rather than to a sliver.
	container:SetHeight(math.abs(y) + PADDING)
end

--------------------------------------------------------------------------------
-- Container
--------------------------------------------------------------------------------

local function SavePosition()
	local point, _, relativePoint, x, y = container:GetPoint()
	PRT.Config.framePoint = point
	PRT.Config.frameRelativePoint = relativePoint
	PRT.Config.frameX = x
	PRT.Config.frameY = y
	PRT.Config:Save()
end

local function CreateContainer()
	local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")

	-- "BackdropTemplate" only supplies the SetBackdrop METHOD; it draws nothing on
	-- its own. Inheriting the template and never calling SetBackdrop is why this
	-- frame was invisible — mixin present, no texture, no border, no pixels.
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	frame:SetBackdropColor(0, 0, 0, 0.55)
	frame:SetBackdropBorderColor(0, 0, 0, 0.9)

	frame:SetSize(ContainerWidth(), HEADER_HEIGHT + PADDING * 2)
	frame:SetPoint(
		PRT.Config.framePoint or "CENTER",
		UIParent,
		PRT.Config.frameRelativePoint or "CENTER",
		PRT.Config.frameX or 320,
		PRT.Config.frameY or 0
	)
	frame:SetClampedToScreen(true)

	titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING)
	titleText:SetWidth(ContentWidth())
	titleText:SetJustifyH("LEFT")
	titleText:SetWordWrap(false)

	ghostText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ghostText:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING - TITLE_HEIGHT)
	ghostText:SetWidth(ContentWidth())
	ghostText:SetJustifyH("LEFT")
	ghostText:SetWordWrap(false)

	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if PRT.Config.lockPosition then return end
		self:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
	end)

	frame:Hide()
	return frame
end

--------------------------------------------------------------------------------
-- Visibility
--
-- ONE predicate, ONE applier, and nothing else may call Show or Hide on the
-- container. Visibility used to be written from three places that each consulted
-- something different: OnEncounterStart showed unconditionally, ApplySettings
-- consulted showCueList, and Toggle consulted nothing at all. The consequence was
-- that showCueList = false held right up until the pull it mattered on, and there
-- was no way to keep the audio while suppressing the display — which is a thing
-- people legitimately want, since the announcements are the product and the list
-- is the readout.
--------------------------------------------------------------------------------

---@return boolean
local function ShouldBeShown()
	-- The master switch. Nothing outranks it, least of all an encounter starting.
	if not PRT.Config.showCueList then return false end

	-- A live encounter is the whole reason the list exists.
	if PRT.Encounter and PRT.Encounter.active then return true end

	-- Out of encounter the frame is the resting card: shown when the player asked
	-- for it by hand, or when they have turned hideOutOfEncounter off.
	if previewOverride then return true end
	return not PRT.Config.hideOutOfEncounter
end

local function ApplyVisibility()
	if not container then return end
	if ShouldBeShown() then
		container:Show()
	else
		container:Hide()
	end
end

--------------------------------------------------------------------------------
-- Public surface
--------------------------------------------------------------------------------

function CueList:Initialize()
	container = CreateContainer()

	pool = PeaversCommons.BarPool:New({
		factory = CreateRow,
		resetter = ResetRow,
		maxPoolSize = 12,
	})

	coordinator = PeaversCommons.UpdateCoordinator:New({
		debounceInterval = 0.05,
		-- "normal", not the default "dataRefreshOnly": this list exists to update
		-- during an encounter, which is by definition in combat.
		combatBehavior = "normal",
		updateHandlers = {
			dataRefresh = Redraw,
			sortRequired = Redraw,
			fullRebuild = function()
				pool:ReleaseAll()
				Redraw()
			end,
		},
	})

	-- Populated before the first redraw can be debounced in, so the frame has
	-- something in it even if /prt arrives in the same frame as login.
	ShowRestingState()
	self:ApplySettings()
end

---Schedules a redraw at `clock`. Called every encounter tick; the coordinator
---collapses the 10Hz stream down to the display's debounce interval.
---@param clock number
function CueList:Refresh(clock)
	if not coordinator then return end
	currentClock = clock or 0
	coordinator:ScheduleUpdate("dataRefresh")
end

---@param encounter table the live PRT.Encounter
function CueList:OnEncounterStart(encounter)
	if not container then return end

	local label = encounter.encounterName or ("Encounter " .. tostring(encounter.encounterID))
	if encounter.synthetic then
		label = "|cffffcc00[test]|r " .. label
	end
	titleText:SetText(label)

	UpdateGhostLine(encounter.timeline)

	currentClock = encounter:GetClock()
	-- Was container:Show(), unconditionally. A pull is not permission to override
	-- the player's own setting.
	ApplyVisibility()
	coordinator:ScheduleUpdate("fullRebuild")
end

function CueList:OnEncounterStop()
	if not container then return end
	pool:ReleaseAll()
	ShowRestingState()
	ApplyVisibility()
end

---Applies size/visibility settings. Row geometry is reapplied by the redraw, so
---this only has to move the container and schedule one.
function CueList:ApplySettings()
	if not container then return end

	container:SetWidth(ContainerWidth())
	titleText:SetWidth(ContentWidth())
	ghostText:SetWidth(ContentWidth())

	ApplyVisibility()

	if coordinator then
		coordinator:ScheduleUpdate("fullRebuild")
	end
end

---ApplySettings, plus the same preview a bare /prt grants.
---
---Every control on the settings pages routes here rather than to ApplySettings
---directly. Out of an encounter, hideOutOfEncounter is on by default, so without
---this a player who ticks "Show the cast list" or drags the width slider sees
---nothing move — adjusting a frame you cannot see is a guessing game, and it
---looks identical to a control that is not wired up.
function CueList:ApplySettingsWithPreview()
	previewOverride = PRT.Config.showCueList and true or false
	self:ApplySettings()
end

---Toggles the list. Bound to a bare /prt.
---
---Writes the SETTING rather than poking the frame. Toggling the frame directly
---left the two disagreeing, so the next pull — or the next settings change —
---silently undid whatever the player had just asked for.
function CueList:Toggle()
	if not container then return end

	local wantShown = not container:IsShown()

	PRT.Config.showCueList = wantShown
	previewOverride = wantShown
	PRT.Config:Save()

	ApplyVisibility()

	if wantShown and coordinator then
		coordinator:ScheduleUpdate("fullRebuild")
	end
end

---@return boolean
function CueList:IsShown()
	return container ~= nil and container:IsShown()
end
