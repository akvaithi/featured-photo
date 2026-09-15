--[[----------------------------------------------------------------------------
MenuSelectNextStack.lua — Library ▸ Plug-in Extras ▸ Select Next Stack

The bridge from a virtual stack to a real one.

Nothing in the SDK stacks photos that are already in the catalog, but the grid
selection *is* settable, and ⌘G stacks the selection. So this walks the stacks
the last scan found, selecting one group at a time with the pick as the active
photo — which is what decides the stack's top frame when you press ⌘G.

Run it, press ⌘G, run it again. Tedious for hundreds of stacks; for the handful
that a normal shoot produces it is the only route to a real stack there is.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FsSettings = require 'FsSettings'

LrTasks.startAsyncTask(function()
	local prefs = FsSettings.prefs()
	local stacks = prefs.lastStacks or {}
	local catalog = LrApplication.activeCatalog()

	if #stacks == 0 then
		LrDialogs.message(
			LOC '$$$/FeaturedStacks/NoRememberedTitle=No stacks to step through',
			LOC '$$$/FeaturedStacks/NoRememberedDetail=Run “Find Auto Stacks…” first, and apply its results.',
			'info')
		return
	end

	local index = tonumber(prefs.nextStackIndex) or 1

	-- Photos can be removed from the catalog between the scan and now, so each
	-- group is resolved and checked before it is offered.
	while index <= #stacks do
		local photos = {}
		for _, uuid in ipairs(stacks[index]) do
			local photo = catalog:findPhotoByUuid(uuid)
			if photo then photos[#photos + 1] = photo end
		end

		if #photos >= 2 then
			-- The first argument becomes the active photo, and ⌘G makes the active
			-- photo the top of the stack. The scan wrote them best-first, so this
			-- puts the pick on top.
			catalog:setSelectedPhotos(photos[1], photos)
			prefs.nextStackIndex = index + 1

			LrDialogs.showBezel(
				LOC('$$$/FeaturedStacks/Bezel=Stack ^1 of ^2 selected — press ⌘G',
					tostring(index), tostring(#stacks)), 4)
			return
		end

		index = index + 1 -- group no longer exists; skip it
	end

	prefs.nextStackIndex = 1
	LrDialogs.message(
		LOC '$$$/FeaturedStacks/AllSteppedTitle=That was the last stack',
		LOC('$$$/FeaturedStacks/AllSteppedDetail=All ^1 stacks from the last scan have been offered. Running this again starts over from the first.',
			tostring(#stacks)),
		'info')
end)
