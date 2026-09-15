--[[----------------------------------------------------------------------------
MenuClearResults.lua — Library ▸ Plug-in Extras ▸ Clear Auto Stack Results

Removes the plug-in's own metadata from everything the last scan touched, and
forgets the remembered groups.

Deliberately narrow: it does not touch pick flags, colour labels or collections,
because by the time someone clears results they may have edited those by hand,
and there is no way to tell an edit from something we wrote. The dialog says so.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FsApply = require 'FsApply'
local FsSettings = require 'FsSettings'

local fields = { 'stackId', 'stackRole', 'stackSize', 'bestShotScore', 'distanceToTop', 'scoreDetail' }

LrTasks.startAsyncTask(function()
	local prefs = FsSettings.prefs()
	local stacks = prefs.lastStacks or {}

	local total = 0
	for _, ids in ipairs(stacks) do total = total + #ids end

	if total == 0 then
		LrDialogs.message(
			LOC '$$$/FeaturedStacks/NothingToClearTitle=Nothing to clear',
			LOC '$$$/FeaturedStacks/NothingToClearDetail=No scan results are being remembered.',
			'info')
		return
	end

	local answer = LrDialogs.confirm(
		LOC('$$$/FeaturedStacks/ClearTitle=Clear the plug-in\'s metadata from ^1 photos?', tostring(total)),
		LOC('$$$/FeaturedStacks/ClearDetail=The score and stack fields this plug-in wrote will be removed. Pick flags, colour labels and the ^1 collections are left alone — clear those yourself if you want them gone. No photo is deleted.',
			FsApply.collectionSetName),
		LOC '$$$/FeaturedStacks/Clear=Clear',
		LOC '$$$/FeaturedStacks/Cancel=Cancel')
	if answer ~= 'ok' then return end

	local catalog = LrApplication.activeCatalog()
	catalog:withPrivateWriteAccessDo(function()
		for _, ids in ipairs(stacks) do
			for _, uuid in ipairs(ids) do
				local photo = catalog:findPhotoByUuid(uuid)
				if photo then
					for _, field in ipairs(fields) do
						photo:setPropertyForPlugin(_PLUGIN, field, nil)
					end
				end
			end
		end
	end, { timeout = 60 })

	FsApply.forget()
	LrDialogs.showBezel(LOC '$$$/FeaturedStacks/Cleared=Auto stack results cleared', 3)
end)
