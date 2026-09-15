--[[----------------------------------------------------------------------------
FsReviewDialog.lua — showing what a scan found.

One row per stack: the pick on the left with its score, the frames it beat to
its right with theirs, and each of those annotated with its feature-print
distance to the pick. That distance is the number to calibrate the similarity
threshold against — a stack full of 0.0x values was never in doubt, a stack with
a 0.45 in it is the threshold doing real work.

This mirrors `StackDetailView` in the macOS app, within what LrView can draw.
------------------------------------------------------------------------------]]

local LrBinding = import 'LrBinding'
local LrColor = import 'LrColor'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'

-- Lightroom runs Lua 5.1, where `unpack` is a global; the test harness runs on
-- whatever `lua` is installed, which since 5.2 only has `table.unpack`.
local unpack = unpack or table.unpack

local FsReviewDialog = {}

-- Building a view per frame is not free, and a big scan can find thousands.
-- Past this the dialog reports the total and shows the newest slice; the
-- collections and metadata still cover every one of them.
local maxStacksShown = 150

local function scoreText(item)
	return string.format('%.3f', item.score or 0)
end

local function summaryLine(result)
	local frames = 0
	for _, stack in ipairs(result.stacks) do frames = frames + #stack.items end
	local kept = #result.stacks
	return LOC('$$$/FeaturedStacks/Summary=^1 stacks over ^2 photos — ^3 picks, ^4 duplicates.',
		tostring(kept), tostring(result.scanned), tostring(kept), tostring(frames - kept))
end

local function stackRow(f, stack, index)
	local frames = {}

	for position, item in ipairs(stack.items) do
		local isTop = position == 1
		local caption
		if isTop then
			caption = LOC('$$$/FeaturedStacks/TopPick=★ ^1', scoreText(item))
		elseif item.distanceToTop then
			caption = LOC('$$$/FeaturedStacks/OtherWithDistance=^1  ·  d ^2',
				scoreText(item), string.format('%.3f', item.distanceToTop))
		else
			caption = scoreText(item)
		end

		frames[#frames + 1] = f:column({
			spacing = 2,
			f:catalog_photo({
				photo = item.photo,
				width = isTop and 108 or 76,
				height = isTop and 108 or 76,
			}),
			f:static_text({
				title = caption,
				font = '<system/small>',
				text_color = isTop and LrColor(0.1, 0.6, 0.2) or nil,
				width = isTop and 108 or 76,
			}),
		})
	end

	local detail = stack.items[1].breakdown
	local subtitle = ''
	if type(detail) == 'table' and (detail.faceCount or 0) > 0 then
		subtitle = LOC('$$$/FeaturedStacks/FaceNote=  ·  ^1 face(s), eyes open ^2%%',
			tostring(detail.faceCount),
			string.format('%.0f', (detail.eyesOpen or 0) * 100))
	end

	return f:group_box({
		title = LOC('$$$/FeaturedStacks/StackTitle=Stack ^1  ·  ^2 frames^3',
			tostring(index), tostring(#stack.items), subtitle),
		fill_horizontal = 1,
		f:row({ spacing = 8, unpack(frames) }),
	})
end

--- Shows the results. Returns the button the user pressed ('ok' or 'cancel').
function FsReviewDialog.show(result, options)
	local f = LrView.osFactory()

	if #result.stacks == 0 then
		LrDialogs.message(
			LOC '$$$/FeaturedStacks/NothingTitle=No stacks found',
			LOC('$$$/FeaturedStacks/NothingDetail=Nothing among the ^1 photos scanned looked like a repeat of another shot. Widen the time window or raise the similarity threshold in the plug-in settings to group more loosely.',
				tostring(result.scanned)),
			'info')
		return 'ok'
	end

	local rows = {}
	for index, stack in ipairs(result.stacks) do
		if index > maxStacksShown then break end
		rows[#rows + 1] = stackRow(f, stack, index)
	end
	if #result.stacks > maxStacksShown then
		rows[#rows + 1] = f:static_text({
			title = LOC('$$$/FeaturedStacks/Truncated=…and ^1 more, not shown here. Every stack is in the collections and the metadata.',
				tostring(#result.stacks - maxStacksShown)),
			font = '<system/small>',
		})
	end

	local notes = {}
	if result.skipped > 0 then
		notes[#notes + 1] = LOC('$$$/FeaturedStacks/SkippedNote=^1 skipped (video, or no capture time)',
			tostring(result.skipped))
	end
	if result.unreadable > 0 then
		notes[#notes + 1] = LOC('$$$/FeaturedStacks/UnreadableNote=^1 could not be read',
			tostring(result.unreadable))
	end

	local contents = f:column({
		bind_to_object = LrBinding.makePropertyTable(nil),
		spacing = f:control_spacing(),

		f:static_text({ title = summaryLine(result), font = '<system/bold>' }),
		#notes > 0 and f:static_text({
			title = table.concat(notes, '  ·  '),
			font = '<system/small>',
		}) or f:spacer({ height = 0 }),

		f:scrolled_view({
			width = 720,
			height = 460,
			f:column({ spacing = 10, unpack(rows) }),
		}),

		f:static_text({
			title = options.applyDescription,
			font = '<system/small>',
			width = 720,
			height_in_lines = 2,
		}),
	})

	return LrDialogs.presentModalDialog({
		title = LOC '$$$/FeaturedStacks/ReviewTitle=Featured Auto Stacks',
		contents = contents,
		actionVerb = options.actionVerb,
		cancelVerb = LOC '$$$/FeaturedStacks/Discard=Discard',
		resizable = true,
	})
end

return FsReviewDialog
