--[[----------------------------------------------------------------------------
MetadataProvider.lua — the plug-in's own metadata fields.

These are the primary output. A pick flag says "this one"; these say why, and
they survive in the catalog where the Library filter and smart collections can
reach them. Two useful rules once a scan has run:

    Stack Role   is   duplicate          -> everything a better frame beat
    Best Shot Score  starts with  0.8    -> the strongest picks in the catalog

Every field is a string because Lightroom's custom metadata has no number type.
Scores are written zero-padded to three decimals (`0.740`), which makes the
lexical sort the filter applies agree with a numeric one.

`schemaVersion` must go up if a field is ever added or renamed.
------------------------------------------------------------------------------]]

return {
	schemaVersion = 1,

	metadataFieldsForPhotos = {
		{
			id = 'stackId',
			title = LOC '$$$/FeaturedStacks/Field/StackId=Stack',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
		{
			id = 'stackRole',
			title = LOC '$$$/FeaturedStacks/Field/StackRole=Stack Role',
			dataType = 'enum',
			values = {
				{ value = 'top', title = LOC '$$$/FeaturedStacks/Role/Top=Top pick' },
				{ value = 'duplicate', title = LOC '$$$/FeaturedStacks/Role/Duplicate=Duplicate' },
			},
			allowPluginToSetOtherValues = false,
			searchable = true,
			browsable = true,
		},
		{
			id = 'stackSize',
			title = LOC '$$$/FeaturedStacks/Field/StackSize=Stack Size',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
		{
			id = 'bestShotScore',
			title = LOC '$$$/FeaturedStacks/Field/Score=Best Shot Score',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
		{
			-- Feature-print distance to the stack's pick. Empty on the pick itself.
			-- This is the number to calibrate the similarity threshold against.
			id = 'distanceToTop',
			title = LOC '$$$/FeaturedStacks/Field/Distance=Distance to Pick',
			dataType = 'string',
			searchable = true,
			browsable = true,
		},
		{
			id = 'scoreDetail',
			title = LOC '$$$/FeaturedStacks/Field/Detail=Score Detail',
			dataType = 'string',
			searchable = true,
			browsable = false, -- too many distinct values to be worth browsing
		},
	},
}
