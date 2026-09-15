--[[----------------------------------------------------------------------------
FsEngine.lua — the scan, end to end.

    target photos
      -> catalog metadata (capture time, orientation, camera)   FsGrouping
      -> candidate groups of 2+
      -> small JPEG renditions                                  FsRenditions
      -> Vision feature prints, sub-clustering, best-shot score  FsScorer
      -> stacks, ranked best first

The split is deliberate: everything cheap happens on metadata over the whole
selection, and only what survives gets rendered. Steps 1-3 mirror `StackStore`
in the macOS app; step 4 mirrors it exactly, because it is the same code.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'

local FsGrouping = require 'FsGrouping'
local FsLogger = require 'FsLogger'
local FsRenditions = require 'FsRenditions'
local FsScorer = require 'FsScorer'

local FsEngine = {}

--- The photos a scan will look at: the selection, or everything in the current
--- source when nothing is selected. That is Lightroom's own convention for what
--- a command acts on.
function FsEngine.targetPhotos()
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	return photos or {}
end

--- Reads what grouping needs out of the catalog, dropping videos and anything
--- with no capture time (which cannot be time-clustered).
---
--- @return table records, number skippedCount
function FsEngine.readRecords(photos, options)
	local catalog = LrApplication.activeCatalog()

	-- Batched: one call for the whole selection rather than a round trip per
	-- photo, which on a few thousand photos is the difference between instant
	-- and a visible stall.
	local raw = catalog:batchGetRawMetadata(photos,
		{ 'uuid', 'dateTimeOriginal', 'dateTime', 'croppedDimensions', 'dimensions', 'isVideo' })

	local formatted
	if options.requireSameCamera then
		formatted = catalog:batchGetFormattedMetadata(photos,
			{ 'cameraMake', 'cameraModel', 'lens' })
	end

	local records, skipped = {}, 0
	for _, photo in ipairs(photos) do
		local meta = raw[photo] or {}
		local time = meta.dateTimeOriginal or meta.dateTime
		local size = meta.croppedDimensions or meta.dimensions or {}

		if meta.isVideo or type(time) ~= 'number' then
			skipped = skipped + 1
		else
			local camera = ''
			if formatted then
				local info = formatted[photo] or {}
				camera = FsGrouping.cameraKey(info.cameraMake, info.cameraModel, info.lens)
			end
			records[#records + 1] = {
				photo = photo,
				id = meta.uuid,
				time = time,
				orientation = FsGrouping.orientationBucket(size.width, size.height),
				camera = camera,
			}
		end
	end
	return records, skipped
end

--- Runs a full scan.
---
--- Must run inside a task. `progress` is an LrProgressScope (or nil); it is
--- polled for cancellation between every stage, so a scan over a large
--- selection stops promptly rather than at the end of the export.
---
--- @return table|nil result, string|nil errorMessage
---   result = { stacks = { { items = { { photo, id, score, distanceToTop, breakdown } } } },
---              scanned =, grouped =, skipped =, unreadable =, canceled = }
function FsEngine.scan(photos, options, progress)
	local function canceled()
		return progress ~= nil and progress:isCanceled()
	end
	local function note(fraction, text)
		if progress then
			progress:setPortionComplete(fraction, 1)
			progress:setCaption(text)
		end
	end

	local available, unavailableMessage = FsScorer.checkAvailable()
	if not available then return nil, unavailableMessage end

	-- 1. Catalog metadata.
	note(0, LOC '$$$/FeaturedStacks/ReadingMetadata=Reading capture times…')
	local records, skipped = FsEngine.readRecords(photos, options)
	if canceled() then return nil, nil end

	-- 2. Time / orientation / camera gating.
	local groups = FsGrouping.candidates(records, options)
	FsLogger.info(string.format('%d photos -> %d candidate groups', #records, #groups))

	local toRender, seen = {}, {}
	for _, group in ipairs(groups) do
		for _, record in ipairs(group) do
			if not seen[record.photo] then
				seen[record.photo] = true
				toRender[#toRender + 1] = record.photo
			end
		end
	end

	if #toRender == 0 then
		return {
			stacks = {}, scanned = #photos, grouped = 0,
			skipped = skipped, unreadable = 0, canceled = false,
		}
	end

	-- 3. Renditions. This is the slow stage, so it owns most of the progress bar.
	local folder = FsRenditions.makeWorkFolder()
	local paths = FsRenditions.render(toRender, folder, options.analysisSize,
		function(done, total)
			note(0.05 + 0.65 * (done / total),
				LOC('$$$/FeaturedStacks/Rendering=Preparing photo ^1 of ^2…',
					tostring(done), tostring(total)))
			return not canceled()
		end)

	if canceled() then
		FsRenditions.cleanUp(folder)
		return nil, nil
	end

	-- 4. Vision. Batched only so the progress bar keeps moving.
	local byId = {}
	local payload = {}
	for _, group in ipairs(groups) do
		local photos_ = {}
		for _, record in ipairs(group) do
			local path = paths[record.photo]
			if path then
				byId[record.id] = record
				photos_[#photos_ + 1] = { id = record.id, path = path }
			end
		end
		-- A group can fall below two once unrenderable frames are dropped.
		if #photos_ >= 2 then payload[#payload + 1] = { photos = photos_ } end
	end

	local batches = FsGrouping.batch(payload, options.batchSize)
	local stacks, unreadable = {}, 0

	for index, batch in ipairs(batches) do
		if canceled() then
			FsRenditions.cleanUp(folder)
			return nil, nil
		end
		note(0.7 + 0.3 * ((index - 1) / #batches),
			LOC('$$$/FeaturedStacks/Analyzing=Analysing group ^1 of ^2…',
				tostring(index), tostring(#batches)))

		local result, message = FsScorer.score(batch, options)
		if not result then
			FsRenditions.cleanUp(folder)
			return nil, message
		end
		unreadable = unreadable + #result.unreadable

		for _, stack in ipairs(result.stacks) do
			local items = {}
			for _, item in ipairs(stack.items) do
				local record = byId[item.id]
				if record then
					items[#items + 1] = {
						photo = record.photo,
						id = item.id,
						score = item.score,
						-- The helper omits distanceToTop for the pick itself.
						distanceToTop = type(item.distanceToTop) == 'number'
							and item.distanceToTop or nil,
						breakdown = item.breakdown,
						time = record.time,
					}
				end
			end
			if #items >= 2 then stacks[#stacks + 1] = { items = items } end
		end
	end

	FsRenditions.cleanUp(folder)

	-- Newest stacks first, matching the app.
	table.sort(stacks, function(a, b)
		return (a.items[1].time or 0) > (b.items[1].time or 0)
	end)

	note(1, LOC '$$$/FeaturedStacks/Finishing=Finishing…')
	return {
		stacks = stacks,
		scanned = #photos,
		grouped = #toRender,
		skipped = skipped,
		unreadable = unreadable,
		canceled = false,
	}
end

return FsEngine
