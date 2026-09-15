--[[----------------------------------------------------------------------------
FsApply.lua — writing a scan's results back into the catalog.

Lightroom Classic's SDK cannot make a real stack. `catalog:addPhoto` takes a
photo to stack a *new* import with, and that is the whole of it — there is no
call that stacks photos already in the catalog, and no way to reach the Photo ▸
Stacking commands. So the results are surfaced four ways instead, each of which
a photographer can act on:

  * plug-in metadata on every frame — searchable and filterable in the Library
    filter, and usable as a smart-collection rule;
  * a pick flag on the best frame of each stack;
  * an optional colour label on it;
  * "Best Picks" and "Duplicates" collections.

The stack membership is also parked in the plug-in's preferences so that
`Select Next Stack` can walk the groups afterwards and hand each one to the grid
selection, where ⌘G makes it a genuine Lightroom stack. See README.md.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'

local FsLogger = require 'FsLogger'
local FsSettings = require 'FsSettings'

local FsApply = {}

FsApply.collectionSetName = 'Featured Auto Stacks'
FsApply.bestPicksName = 'Best Picks'
FsApply.duplicatesName = 'Duplicates'

--- Zero-padded so the Library filter sorts these as numbers rather than text.
local function formatScore(value)
	if type(value) ~= 'number' then return nil end
	return string.format('%.3f', value)
end

local function describe(breakdown)
	if type(breakdown) ~= 'table' then return nil end
	local parts = {
		string.format('aesthetic %.2f', breakdown.aesthetic or 0),
	}
	if (breakdown.faceCount or 0) > 0 then
		parts[#parts + 1] = string.format('%d face%s', breakdown.faceCount,
			breakdown.faceCount == 1 and '' or 's')
		parts[#parts + 1] = string.format('capture %.2f', breakdown.faceQuality or 0)
		parts[#parts + 1] = string.format('eyes open %.0f%%', (breakdown.eyesOpen or 0) * 100)
		parts[#parts + 1] = string.format('smiling %.0f%%', (breakdown.smiling or 0) * 100)
	end
	if breakdown.isUtility then parts[#parts + 1] = 'screenshot/document' end
	return table.concat(parts, ', ')
end

--- A short id for one stack, stable within a scan and sortable in the filter.
local function stackId(index)
	return string.format('stack-%04d', index)
end

--- Writes the plug-in's own metadata fields. Plug-in properties go through
--- private write access, which does not mark the catalog dirty for the user.
local function writeMetadata(catalog, stacks)
	catalog:withPrivateWriteAccessDo(function()
		for index, stack in ipairs(stacks) do
			local id = stackId(index)
			for position, item in ipairs(stack.items) do
				local photo = item.photo
				photo:setPropertyForPlugin(_PLUGIN, 'stackId', id)
				photo:setPropertyForPlugin(_PLUGIN, 'stackRole',
					position == 1 and 'top' or 'duplicate')
				photo:setPropertyForPlugin(_PLUGIN, 'stackSize', tostring(#stack.items))
				photo:setPropertyForPlugin(_PLUGIN, 'bestShotScore', formatScore(item.score))
				photo:setPropertyForPlugin(_PLUGIN, 'distanceToTop', formatScore(item.distanceToTop))
				photo:setPropertyForPlugin(_PLUGIN, 'scoreDetail', describe(item.breakdown))
			end
		end
	end, { timeout = 60 })
end

local function writeFlagsAndLabels(catalog, stacks, options)
	catalog:withWriteAccessDo(LOC '$$$/FeaturedStacks/UndoFlags=Featured Auto Stacks', function()
		for _, stack in ipairs(stacks) do
			for position, item in ipairs(stack.items) do
				local photo = item.photo
				if position == 1 then
					if options.setPickFlags then photo:setRawMetadata('pickStatus', 1) end
					if options.labelTopPick then
						photo:setRawMetadata('colorNameForLabel', options.topPickLabel)
					end
				elseif options.rejectOthers then
					photo:setRawMetadata('pickStatus', -1)
				end
			end
		end
	end, { timeout = 60 })
end

local function writeCollections(catalog, stacks, options)
	catalog:withWriteAccessDo(LOC '$$$/FeaturedStacks/UndoCollections=Featured Auto Stacks collections', function()
		local set = catalog:createCollectionSet(FsApply.collectionSetName, nil, true)

		local picks, duplicates = {}, {}
		for _, stack in ipairs(stacks) do
			for position, item in ipairs(stack.items) do
				if position == 1 then
					picks[#picks + 1] = item.photo
				else
					duplicates[#duplicates + 1] = item.photo
				end
			end
		end

		-- Rebuilt from scratch each scan: a collection still holding the previous
		-- run's photos would quietly mix two sets of results.
		local best = catalog:createCollection(FsApply.bestPicksName, set, true)
		best:removeAllPhotos()
		best:addPhotos(picks)

		local dupes = catalog:createCollection(FsApply.duplicatesName, set, true)
		dupes:removeAllPhotos()
		dupes:addPhotos(duplicates)

		if options.perStackCollections then
			local perStack = catalog:createCollectionSet('Stacks', set, true)
			for _, child in ipairs(perStack:getChildCollections()) do
				child:delete()
			end
			for index, stack in ipairs(stacks) do
				local name = string.format('%s (%d)', stackId(index), #stack.items)
				local collection = catalog:createCollection(name, perStack, true)
				collection:removeAllPhotos()
				local photos = {}
				for _, item in ipairs(stack.items) do photos[#photos + 1] = item.photo end
				collection:addPhotos(photos)
			end
		end
	end, { timeout = 120 })
end

--- Remembers stack membership by uuid, so `Select Next Stack` can walk the
--- groups in a later, separate invocation of the plug-in.
local function rememberStacks(stacks)
	local prefs = FsSettings.prefs()
	local remembered = {}
	for index, stack in ipairs(stacks) do
		local ids = {}
		for _, item in ipairs(stack.items) do ids[#ids + 1] = item.id end
		remembered[index] = ids
	end
	-- LrPrefs only persists a whole assignment, never a mutation in place.
	prefs.lastStacks = remembered
	prefs.nextStackIndex = 1
end

--- Applies everything the settings ask for. Must run inside a task.
--- @return boolean ok, string|nil errorMessage
function FsApply.apply(stacks, options)
	if #stacks == 0 then
		FsApply.forget()
		return true
	end
	local catalog = LrApplication.activeCatalog()

	local ok, err = pcall(function()
		if options.writeMetadata then writeMetadata(catalog, stacks) end
		if options.setPickFlags or options.rejectOthers or options.labelTopPick then
			writeFlagsAndLabels(catalog, stacks, options)
		end
		if options.buildCollections then writeCollections(catalog, stacks, options) end
		rememberStacks(stacks)
	end)

	if not ok then
		FsLogger.error('applying results failed: ' .. tostring(err))
		return false, tostring(err)
	end
	FsLogger.info(string.format('applied %d stacks', #stacks))
	return true
end

--- Drops the remembered stacks (after the user has stacked them, or on request).
function FsApply.forget()
	local prefs = FsSettings.prefs()
	prefs.lastStacks = {}
	prefs.nextStackIndex = 1
end

return FsApply
