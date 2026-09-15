--[[----------------------------------------------------------------------------
FsRenditions.lua — getting pixels out of Lightroom.

The SDK offers no way to read a photo's preview, so the sanctioned route to
pixels is an export. These renditions are throwaway: small sRGB JPEGs in a temp
folder, deleted as soon as the helper has looked at them.

Exporting is by far the slowest part of a scan, which is why FsGrouping runs
first — only frames that already share a capture time, an orientation and a
camera ever get here.
------------------------------------------------------------------------------]]

local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local FsLogger = require 'FsLogger'

local FsRenditions = {}

--- A fresh temp folder for one scan. The caller must pass it to `cleanUp`.
function FsRenditions.makeWorkFolder()
	local base = LrPathUtils.getStandardFilePath('temp')
	local path = LrPathUtils.child(base, string.format('featured-stacks-%d-%d',
		os.time(), math.random(100000, 999999)))
	LrFileUtils.createAllDirectories(path)
	return path
end

function FsRenditions.cleanUp(folder)
	if folder and LrFileUtils.exists(folder) then
		local ok, err = pcall(LrFileUtils.delete, folder)
		if not ok then FsLogger.warn('could not remove ' .. folder .. ': ' .. tostring(err)) end
	end
end

local function exportSettings(folder, size)
	return {
		LR_export_destinationType = 'specificFolder',
		LR_export_destinationPathPrefix = folder,
		LR_export_useSubfolder = false,
		-- Two photos in a catalog can share a filename; without this the second
		-- rendition would overwrite the first and both would score identically.
		LR_collisionHandling = 'rename',
		LR_export_videoFileHandling = 'exclude',
		LR_reimportExportedPhoto = false,
		LR_renamingTokensOn = false,

		LR_format = 'JPEG',
		LR_jpeg_quality = 0.6, -- analysis only; artefacts at this size are invisible to Vision
		LR_jpeg_useLimitSize = false,
		LR_export_bitDepth = 8,
		LR_export_colorSpace = 'sRGB',

		LR_size_doConstrain = true,
		LR_size_resizeType = 'wh',
		LR_size_units = 'pixels',
		LR_size_maxWidth = size,
		LR_size_maxHeight = size,
		LR_size_doNotEnlarge = true,
		LR_outputSharpeningOn = false,
		LR_useWatermark = false,

		-- Nothing downstream reads metadata, and stripping it keeps a stray
		-- rendition from carrying the photo's location into a temp folder.
		LR_removeLocationMetadata = true,
		LR_embeddedMetadataOption = 'copyrightOnly',
		LR_metadata_keywordOptions = 'flat',
	}
end

--- Renders `photos` into `folder`.
---
--- Must run inside a task (waitForRender yields).
---
--- @param photos table     array of LrPhoto
--- @param folder string    destination, from makeWorkFolder
--- @param size number      longest edge in pixels
--- @param onProgress function|nil  called as (done, total); returning false cancels
--- @return table  map of photo (LrPhoto) -> absolute rendition path
function FsRenditions.render(photos, folder, size, onProgress)
	local paths = {}
	if #photos == 0 then return paths end

	local session = LrExportSession({
		photosToExport = photos,
		exportSettings = exportSettings(folder, size),
	})

	local done = 0
	for _, rendition in session:renditions({ stopIfCanceled = true }) do
		local ok, result = rendition:waitForRender()
		if ok then
			paths[rendition.photo] = result
		else
			-- A missing original or an offline volume lands here. It is not fatal:
			-- the photo simply never reaches the helper and never gets stacked.
			FsLogger.warn('could not render a photo: ' .. tostring(result))
		end
		done = done + 1
		if onProgress and onProgress(done, #photos) == false then
			break
		end
	end

	return paths
end

return FsRenditions
