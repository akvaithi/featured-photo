--[[----------------------------------------------------------------------------
MenuFindStacks.lua — Library ▸ Plug-in Extras ▸ Find Auto Stacks…

Scans the selection (or the whole current source when nothing is selected),
shows what it found, and applies the results if the user accepts them.
------------------------------------------------------------------------------]]

local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'

local FsApply = require 'FsApply'
local FsEngine = require 'FsEngine'
local FsLogger = require 'FsLogger'
local FsReviewDialog = require 'FsReviewDialog'
local FsSettings = require 'FsSettings'

--- Reads the preferences into the plain option table the engine wants, coercing
--- anything the settings dialog's text fields may have had typed into them.
local function optionsFromPrefs(prefs)
	return {
		timeWindow = FsSettings.number(prefs.timeWindow, 12, 0.1, 3600),
		similarityThreshold = FsSettings.number(prefs.similarityThreshold, 0.5, 0.01, 2),
		requireSameCamera = prefs.requireSameCamera and true or false,
		analysisSize = FsSettings.number(prefs.analysisSize, 256, 64, 1024),
		batchSize = FsSettings.number(prefs.batchSize, 40, 1, 500),
		maxPhotos = FsSettings.number(prefs.maxPhotos, 5000, 1, 1000000),

		setPickFlags = prefs.setPickFlags and true or false,
		rejectOthers = prefs.rejectOthers and true or false,
		labelTopPick = prefs.labelTopPick and true or false,
		topPickLabel = prefs.topPickLabel or 'green',
		buildCollections = prefs.buildCollections and true or false,
		perStackCollections = prefs.perStackCollections and true or false,
		writeMetadata = prefs.writeMetadata and true or false,
	}
end

--- One line telling the user exactly what pressing Apply will change.
local function applyDescription(options)
	local parts = {}
	if options.writeMetadata then
		parts[#parts + 1] = LOC '$$$/FeaturedStacks/WillMetadata=write the plug-in\'s score fields'
	end
	if options.setPickFlags then
		parts[#parts + 1] = LOC '$$$/FeaturedStacks/WillFlag=flag each pick'
	end
	if options.rejectOthers then
		parts[#parts + 1] = LOC '$$$/FeaturedStacks/WillReject=mark the rest as rejects'
	end
	if options.labelTopPick then
		parts[#parts + 1] = LOC('$$$/FeaturedStacks/WillLabel=label each pick ^1', options.topPickLabel)
	end
	if options.buildCollections then
		parts[#parts + 1] = LOC '$$$/FeaturedStacks/WillCollect=rebuild the Best Picks and Duplicates collections'
	end
	if #parts == 0 then
		return LOC '$$$/FeaturedStacks/WillNothing=Every output is switched off in the plug-in settings, so Apply will only remember these stacks for “Select Next Stack”. Nothing is deleted either way.'
	end
	return LOC('$$$/FeaturedStacks/WillDo=Apply will ^1. Nothing is deleted, and every change is undoable.',
		table.concat(parts, ', '))
end

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('featuredStacksScan', function(context)
		local prefs = FsSettings.prefs()
		FsLogger.setEnabled(prefs.logging)
		local options = optionsFromPrefs(prefs)

		local photos = FsEngine.targetPhotos()
		if #photos == 0 then
			LrDialogs.message(
				LOC '$$$/FeaturedStacks/NoPhotosTitle=Nothing to scan',
				LOC '$$$/FeaturedStacks/NoPhotosDetail=Select some photos, or pick a folder or collection to scan.',
				'info')
			return
		end

		if #photos > options.maxPhotos then
			local answer = LrDialogs.confirm(
				LOC('$$$/FeaturedStacks/BigScanTitle=Scan ^1 photos?', tostring(#photos)),
				LOC('$$$/FeaturedStacks/BigScanDetail=That is above the ^1-photo limit in the plug-in settings. Only photos that share a capture time, orientation and camera are ever rendered, but a scan this size can still take a while.',
					tostring(options.maxPhotos)),
				LOC '$$$/FeaturedStacks/ScanAnyway=Scan anyway',
				LOC '$$$/FeaturedStacks/Cancel=Cancel')
			if answer ~= 'ok' then return end
		end

		local progress = LrDialogs.showModalProgressDialog({
			title = LOC '$$$/FeaturedStacks/ScanTitle=Finding auto stacks',
			caption = LOC '$$$/FeaturedStacks/Starting=Starting…',
			cannotCancel = false,
			functionContext = context,
		})

		local result, message = FsEngine.scan(photos, options, progress)
		progress:done()

		if not result then
			if message then
				FsLogger.error('scan failed: ' .. tostring(message))
				LrDialogs.message(LOC '$$$/FeaturedStacks/ScanFailed=The scan could not finish',
					message, 'critical')
			end
			return -- no message means the user cancelled
		end

		local button = FsReviewDialog.show(result, {
			actionVerb = LOC '$$$/FeaturedStacks/Apply=Apply',
			applyDescription = applyDescription(options),
		})
		if button ~= 'ok' or #result.stacks == 0 then return end

		local ok, applyError = FsApply.apply(result.stacks, options)
		if not ok then
			LrDialogs.message(LOC '$$$/FeaturedStacks/ApplyFailed=The results could not be written',
				applyError, 'critical')
			return
		end

		LrDialogs.message(
			LOC('$$$/FeaturedStacks/AppliedTitle=Applied ^1 stacks', tostring(#result.stacks)),
			LOC '$$$/FeaturedStacks/AppliedDetail=Lightroom Classic\'s SDK cannot create a stack, so these are surfaced as metadata, flags and collections. To turn them into real Lightroom stacks, run “Select Next Stack” from the same menu and press ⌘G (Ctrl+G on Windows) for each one.',
			'info')
	end)
end)
