--[[----------------------------------------------------------------------------
FsSettings.lua — tunable knobs, persisted in the plug-in's preferences.

The defaults are the macOS app's `StackConfig` defaults, so a library scanned
either way groups the same. Where they differ, the difference is noted.
------------------------------------------------------------------------------]]

local LrPrefs = import 'LrPrefs'

local FsSettings = {}

FsSettings.defaults = {
	-- Max seconds between consecutive shots to count as the same burst.
	timeWindow = 12,
	-- Feature-print distance below which two frames are "the same shot".
	-- Lower is stricter. The review dialog's "distance to top" column is what
	-- you calibrate this against.
	similarityThreshold = 0.5,
	-- Only group frames from the same camera and lens (EXIF make/model/lens).
	requireSameCamera = true,
	-- Longest edge Vision analyses. The app uses 256; renditions cost more to
	-- produce here than a PhotoKit thumbnail does, but not enough to lower it.
	analysisSize = 256,
	-- Refuse to start above this many photos, so an accidental "all photographs"
	-- on a 200k catalog asks first rather than exporting for an hour.
	maxPhotos = 5000,
	-- How many groups go to the helper per invocation. Purely a progress-bar
	-- granularity knob: one call for everything would show no movement.
	batchSize = 40,

	-- What to do with the results.
	setPickFlags = true,          -- flag the best frame of each stack
	rejectOthers = false,         -- flag the rest as rejects (off: it arms Delete Rejected)
	labelTopPick = false,         -- colour label on the best frame
	topPickLabel = 'green',
	buildCollections = true,      -- "Best Picks" / "Duplicates" collections
	perStackCollections = false,  -- plus one collection per stack
	writeMetadata = true,         -- the plug-in's own searchable fields

	logging = false,
}

--- The live preference table. Assigning a field persists it.
function FsSettings.prefs()
	local prefs = LrPrefs.prefsForPlugin()
	for key, value in pairs(FsSettings.defaults) do
		if prefs[key] == nil then prefs[key] = value end
	end
	return prefs
end

--- Puts every knob back to its default.
function FsSettings.reset()
	local prefs = LrPrefs.prefsForPlugin()
	for key, value in pairs(FsSettings.defaults) do
		prefs[key] = value
	end
	return prefs
end

--- Coerces a preference to a sane number, since the dialog's text fields let a
--- user type anything at all into them.
function FsSettings.number(value, fallback, minimum, maximum)
	local n = tonumber(value)
	if n == nil then return fallback end
	if minimum and n < minimum then return minimum end
	if maximum and n > maximum then return maximum end
	return n
end

return FsSettings
