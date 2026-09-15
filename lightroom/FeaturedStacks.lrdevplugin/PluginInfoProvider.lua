--[[----------------------------------------------------------------------------
PluginInfoProvider.lua — the panel in File ▸ Plug-in Manager.

Holds every tuning knob, plus a button that proves the native helper actually
runs. The defaults are the macOS app's, so the same library groups the same way
through either front end.
------------------------------------------------------------------------------]]

local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local FsLogger = require 'FsLogger'
local FsScorer = require 'FsScorer'
local FsSettings = require 'FsSettings'

local labels = { 'red', 'yellow', 'green', 'blue', 'purple' }

local function labelItems()
	local items = {}
	for _, name in ipairs(labels) do
		items[#items + 1] = { title = name:sub(1, 1):upper() .. name:sub(2), value = name }
	end
	return items
end

return {

	sectionsForTopOfDialog = function(f, properties)
		local prefs = FsSettings.prefs()
		FsLogger.setEnabled(prefs.logging)

		-- Running the helper yields, and this function is called on the main
		-- thread while the panel is being assembled, so the version cannot be
		-- fetched here. Fill it in from a task and let the binding update it.
		properties.helperVersion = LOC '$$$/FeaturedStacks/Checking=checking…'
		LrTasks.startAsyncTask(function()
			local version = FsScorer.version()
			properties.helperVersion = version
				or LOC '$$$/FeaturedStacks/HelperMissing=not available'
		end)

		return {
			{
				title = LOC '$$$/FeaturedStacks/Section/Grouping=Grouping',

				f:row({
					f:static_text({
						title = LOC '$$$/FeaturedStacks/TimeWindow=Time window:',
						width = LrView.share('fs_label'),
						alignment = 'right',
					}),
					f:edit_field({
						value = LrView.bind({ key = 'timeWindow', bind_to_object = prefs }),
						width_in_digits = 6,
						precision = 1,
						min = 0.1,
						max = 3600,
					}),
					f:static_text({
						title = LOC '$$$/FeaturedStacks/Seconds=seconds between consecutive frames',
					}),
				}),

				f:row({
					f:static_text({
						title = LOC '$$$/FeaturedStacks/Similarity=Similarity threshold:',
						width = LrView.share('fs_label'),
						alignment = 'right',
					}),
					f:edit_field({
						value = LrView.bind({ key = 'similarityThreshold', bind_to_object = prefs }),
						width_in_digits = 6,
						precision = 2,
						min = 0.01,
						max = 2,
					}),
					f:static_text({
						title = LOC '$$$/FeaturedStacks/SimilarityHint=lower groups more strictly',
					}),
				}),

				f:row({
					f:static_text({ title = '', width = LrView.share('fs_label') }),
					f:checkbox({
						title = LOC '$$$/FeaturedStacks/SameCamera=Only group frames from the same camera and lens',
						value = LrView.bind({ key = 'requireSameCamera', bind_to_object = prefs }),
					}),
				}),

				f:row({
					f:static_text({
						title = LOC '$$$/FeaturedStacks/MaxPhotos=Ask above:',
						width = LrView.share('fs_label'),
						alignment = 'right',
					}),
					f:edit_field({
						value = LrView.bind({ key = 'maxPhotos', bind_to_object = prefs }),
						width_in_digits = 8,
						precision = 0,
						min = 1,
						max = 1000000,
					}),
					f:static_text({ title = LOC '$$$/FeaturedStacks/PhotosWord=photos in one scan' }),
				}),

				f:static_text({
					title = LOC '$$$/FeaturedStacks/GroupingHint=The “Distance to Pick” column in the review dialog is what you calibrate the similarity threshold against: a stack whose frames all sit near 0.0 was never in doubt.',
					font = '<system/small>',
					width = 560,
					height_in_lines = 2,
				}),
			},

			{
				title = LOC '$$$/FeaturedStacks/Section/Results=What to do with the results',

				f:checkbox({
					title = LOC '$$$/FeaturedStacks/WriteMetadata=Write this plug-in\'s score and stack fields',
					value = LrView.bind({ key = 'writeMetadata', bind_to_object = prefs }),
				}),
				f:checkbox({
					title = LOC '$$$/FeaturedStacks/PickFlags=Flag the best frame of each stack as a pick',
					value = LrView.bind({ key = 'setPickFlags', bind_to_object = prefs }),
				}),
				f:checkbox({
					title = LOC '$$$/FeaturedStacks/Reject=Flag the other frames as rejects',
					value = LrView.bind({ key = 'rejectOthers', bind_to_object = prefs }),
				}),
				f:static_text({
					title = LOC '$$$/FeaturedStacks/RejectHint=Off by default: rejects are what Photo ▸ Delete Rejected Photos acts on, and a mis-picked frame is easy to miss in that dialog.',
					font = '<system/small>',
					width = 560,
					height_in_lines = 2,
				}),

				f:row({
					f:checkbox({
						title = LOC '$$$/FeaturedStacks/Label=Label the best frame',
						value = LrView.bind({ key = 'labelTopPick', bind_to_object = prefs }),
					}),
					f:popup_menu({
						value = LrView.bind({ key = 'topPickLabel', bind_to_object = prefs }),
						items = labelItems(),
						enabled = LrView.bind({ key = 'labelTopPick', bind_to_object = prefs }),
					}),
				}),

				f:checkbox({
					title = LOC '$$$/FeaturedStacks/Collections=Build “Best Picks” and “Duplicates” collections',
					value = LrView.bind({ key = 'buildCollections', bind_to_object = prefs }),
				}),
				f:checkbox({
					title = LOC '$$$/FeaturedStacks/PerStack=…and one collection per stack',
					value = LrView.bind({ key = 'perStackCollections', bind_to_object = prefs }),
					enabled = LrView.bind({ key = 'buildCollections', bind_to_object = prefs }),
				}),
			},

			{
				title = LOC '$$$/FeaturedStacks/Section/Helper=Scoring helper',

				f:row({
					f:static_text({ title = LOC '$$$/FeaturedStacks/HelperVersion=Version:' }),
					f:static_text({
						title = LrView.bind({ key = 'helperVersion', bind_to_object = properties }),
						width_in_chars = 20,
					}),
					f:push_button({
						title = LOC '$$$/FeaturedStacks/TestHelper=Test',
						action = function()
							-- Button actions are not tasks, and the helper yields.
							LrTasks.startAsyncTask(function()
								FsScorer.forget()
								local version = FsScorer.version()
								if version then
									properties.helperVersion = version
									LrDialogs.message(
										LOC '$$$/FeaturedStacks/HelperOkTitle=The scoring helper works',
										LOC('$$$/FeaturedStacks/HelperOkDetail=featured-scorer ^1 at ^2',
											version, FsScorer.binaryPath()), 'info')
								else
									local _, message = FsScorer.checkAvailable()
									properties.helperVersion =
										LOC '$$$/FeaturedStacks/HelperMissing=not available'
									LrDialogs.message(
										LOC '$$$/FeaturedStacks/HelperBadTitle=The scoring helper did not run',
										message or LOC('$$$/FeaturedStacks/HelperBadDetail=Nothing came back from ^1',
											FsScorer.binaryPath()), 'critical')
								end
							end)
						end,
					}),
				}),

				f:static_text({
					title = LOC '$$$/FeaturedStacks/HelperHint=Similarity and best-shot scoring use Apple\'s Vision framework, so they are macOS only. Build the helper with lightroom/scripts/build-scorer.sh.',
					font = '<system/small>',
					width = 560,
					height_in_lines = 2,
				}),

				f:row({
					f:checkbox({
						title = LOC '$$$/FeaturedStacks/Logging=Write a log file',
						value = LrView.bind({ key = 'logging', bind_to_object = prefs }),
					}),
					f:push_button({
						title = LOC '$$$/FeaturedStacks/Reset=Reset all settings',
						action = function()
							FsSettings.reset()
						end,
					}),
				}),
			},
		}
	end,
}
