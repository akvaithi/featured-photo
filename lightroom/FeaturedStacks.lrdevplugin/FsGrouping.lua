--[[----------------------------------------------------------------------------
FsGrouping.lua — the catalog-metadata half of the grouping pipeline.

This is `StackStore.clusterByTime` plus its orientation/camera partitioning,
moved ahead of the pixel work. Nothing here needs an image, so it runs over the
whole selection first and only the survivors — groups of two or more frames that
could plausibly be the same shot — are ever rendered and handed to the helper.
On a real catalog that is the difference between exporting everything and
exporting a few percent of it.

Pure Lua on plain tables, so the test harness can drive it without Lightroom.
------------------------------------------------------------------------------]]

local FsGrouping = {}

--- Coarse orientation bucket. Frames only group with the same bucket, which is
--- what stops a portrait and a landscape frame of the same scene from merging.
--- Thresholds match `PhotoOrientation` in the macOS app.
function FsGrouping.orientationBucket(width, height)
	width, height = tonumber(width), tonumber(height)
	if not width or not height or width <= 0 or height <= 0 then return 'square' end
	local ratio = width / height
	if ratio > 1.15 then return 'landscape' end
	if ratio < 0.87 then return 'portrait' end
	return 'square'
end

--- Builds the "same camera" key from EXIF make, model and lens, e.g.
--- "Apple · iPhone 15 Pro · back triple camera". Empty when nothing is known,
--- which groups all such frames together rather than isolating each one.
function FsGrouping.cameraKey(make, model, lens)
	local parts = {}
	for _, value in ipairs({ make, model, lens }) do
		if type(value) == 'string' then
			local trimmed = value:match('^%s*(.-)%s*$')
			if trimmed ~= '' then parts[#parts + 1] = trimmed end
		end
	end
	return table.concat(parts, ' · ')
end

--- Splits records into runs of consecutive frames taken within `window` seconds
--- of each other. Records must carry a numeric `time`; the caller sorts.
---
--- The comparison is against the *previous frame*, not the run's start, so a
--- long continuous burst stays one run instead of being cut every `window`
--- seconds. That matches the app.
function FsGrouping.clusterByTime(records, window)
	local clusters, current, lastTime = {}, {}, nil
	for _, record in ipairs(records) do
		local time = record.time
		if lastTime and (time - lastTime) <= window then
			current[#current + 1] = record
		else
			if #current > 0 then clusters[#clusters + 1] = current end
			current = { record }
		end
		lastTime = time
	end
	if #current > 0 then clusters[#clusters + 1] = current end
	return clusters
end

--- Splits one time cluster by orientation, and by camera when `requireSameCamera`.
--- Returns only the partitions with two or more frames, each still in capture order.
function FsGrouping.partition(cluster, requireSameCamera)
	local buckets, order = {}, {}
	for _, record in ipairs(cluster) do
		local key = record.orientation .. '#' .. (requireSameCamera and (record.camera or '') or '')
		if not buckets[key] then
			buckets[key] = {}
			order[#order + 1] = key
		end
		local bucket = buckets[key]
		bucket[#bucket + 1] = record
	end

	local partitions = {}
	for _, key in ipairs(order) do
		if #buckets[key] >= 2 then partitions[#partitions + 1] = buckets[key] end
	end
	return partitions
end

--- The whole metadata pass: sort, cluster by time, partition, keep groups of 2+.
---
--- @param records table  { { id =, time =, orientation =, camera =, photo = }, ... }
--- @param options table  { timeWindow =, requireSameCamera = }
--- @return table  array of arrays of records, in capture order
function FsGrouping.candidates(records, options)
	local sorted = {}
	for index, record in ipairs(records) do
		-- Stable: equal capture times keep catalog order, so a burst written with
		-- one-second EXIF resolution does not reshuffle between runs.
		sorted[index] = { record = record, index = index }
	end
	table.sort(sorted, function(a, b)
		if a.record.time == b.record.time then return a.index < b.index end
		return a.record.time < b.record.time
	end)

	local ordered = {}
	for index, entry in ipairs(sorted) do ordered[index] = entry.record end

	local groups = {}
	for _, cluster in ipairs(FsGrouping.clusterByTime(ordered, options.timeWindow)) do
		if #cluster >= 2 then
			for _, partition in ipairs(FsGrouping.partition(cluster, options.requireSameCamera)) do
				groups[#groups + 1] = partition
			end
		end
	end
	return groups
end

--- Splits `groups` into chunks of at most `size` groups, one helper invocation
--- each. Only affects how often the progress bar moves.
function FsGrouping.batch(groups, size)
	local batches, current = {}, {}
	for _, group in ipairs(groups) do
		current[#current + 1] = group
		if #current >= size then
			batches[#batches + 1] = current
			current = {}
		end
	end
	if #current > 0 then batches[#batches + 1] = current end
	return batches
end

return FsGrouping
