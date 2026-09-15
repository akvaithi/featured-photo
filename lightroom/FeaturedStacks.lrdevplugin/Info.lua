--[[----------------------------------------------------------------------------
Info.lua — plugin manifest for Featured Photo's Lightroom Classic front end.

Lightroom loads a plug-in by reading Info.lua from the .lrdevplugin bundle.
------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 13.0,
	LrSdkMinimumVersion = 13.0,

	LrToolkitIdentifier = 'com.akvaithi.lightroom.featuredstacks',
	LrPluginName = LOC '$$$/FeaturedStacks/PluginName=Featured Photo — Auto Stacks',
	LrPluginInfoUrl = 'https://github.com/akvaithi/featured-photo',

	LrLibraryMenuItems = {
		{
			title = LOC '$$$/FeaturedStacks/Menu/Find=Find Auto Stacks…',
			file = 'MenuFindStacks.lua',
		},
		{
			-- The manual half of stacking: the SDK cannot press ⌘G for you.
			title = LOC '$$$/FeaturedStacks/Menu/Next=Select Next Stack',
			file = 'MenuSelectNextStack.lua',
		},
		{
			title = LOC '$$$/FeaturedStacks/Menu/Clear=Clear Auto Stack Results',
			file = 'MenuClearResults.lua',
		},
	},

	LrMetadataProvider = 'MetadataProvider.lua',
	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	VERSION = { major = 0, minor = 1, revision = 0, build = 0 },
}
