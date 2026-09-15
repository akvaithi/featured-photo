--[[----------------------------------------------------------------------------
test_plugin.lua — exercises the plug-in's non-UI logic against the real native
helper.

  lua lightroom/tests/test_plugin.lua <path-to-featured-scorer> [tmpdir]

The binary is copied into the plug-in's bin/macOS slot first, so the test covers
FsScorer's real path resolution, shell quoting and JSON handling rather than a
mock of them. Fixture images are synthesised as BMPs, which ImageIO reads and
which can be written from Lua with no dependencies — so the similarity and
threshold assertions are exact rather than dependent on sample photos.
------------------------------------------------------------------------------]]

local scriptDir = arg[0]:match('^(.*)[/\\][^/\\]*$') or '.'
local sourcePlugin = scriptDir .. '/../FeaturedStacks.lrdevplugin'
package.path = scriptDir .. '/?.lua;' .. package.path

local scorerBinary = arg[1]
local tmpDir = arg[2] or (os.getenv('TMPDIR') or '/tmp')
if not scorerBinary then
	io.stderr:write('usage: test_plugin.lua <featured-scorer> [tmpdir]\n')
	os.exit(2)
end
tmpDir = tmpDir:gsub('/$', '')

-- Work against a copy of the bundle: the harness pretends to be macOS, so
-- installing the binary into the real tree would leave a host-only binary in
-- the macOS slot for a later packaging step to pick up.
local workRoot = tmpDir .. '/featured-stacks-test'
local pluginPath = workRoot .. '/FeaturedStacks.lrdevplugin'
os.execute(string.format('rm -rf %q && mkdir -p %q && cp -R %q/. %q',
	workRoot, pluginPath, sourcePlugin, pluginPath))
os.execute(string.format('mkdir -p %q/bin/macOS && cp %q %q/bin/macOS/featured-scorer',
	pluginPath, scorerBinary, pluginPath))

local stubs = require 'lr_stubs'
stubs.install(pluginPath)
stubs.tempDir = workRoot

local failures = 0
local function check(condition, description)
	if condition then
		print('ok   ' .. description)
	else
		print('FAIL ' .. description)
		failures = failures + 1
	end
end

-- MARK: - Fixture images
--
-- A 24-bit BMP: 14-byte file header, 40-byte info header, then bottom-up BGR
-- rows padded to a multiple of four bytes.

local function le(value, bytes)
	local out = {}
	for _ = 1, bytes do
		out[#out + 1] = string.char(value % 256)
		value = math.floor(value / 256)
	end
	return table.concat(out)
end

local function writeBmp(path, size, pixel)
	local rowBytes = size * 3
	local padding = (4 - rowBytes % 4) % 4
	local imageSize = (rowBytes + padding) * size

	local rows = {}
	for y = size - 1, 0, -1 do
		local row = {}
		for x = 0, size - 1 do
			local r, g, b = pixel(x, y)
			row[#row + 1] = string.char(b, g, r)
		end
		rows[#rows + 1] = table.concat(row) .. string.rep('\0', padding)
	end

	local file = assert(io.open(path, 'wb'))
	file:write('BM', le(54 + imageSize, 4), le(0, 4), le(54, 4))
	file:write(le(40, 4), le(size, 4), le(size, 4), le(1, 2), le(24, 2), le(0, 4),
		le(imageSize, 4), le(2835, 4), le(2835, 4), le(0, 4), le(0, 4))
	file:write(table.concat(rows))
	file:close()
	return path
end

local fixtures = workRoot .. '/fixtures'
os.execute(string.format('mkdir -p %q', fixtures))

-- A structured scene, a byte-identical copy of it, and something with nothing
-- in common with either.
local sceneA = writeBmp(fixtures .. '/a.bmp', 96, function(x, y)
	local r = (x * 2) % 256
	local g = (y * 2) % 256
	local b = ((x + y) % 32) * 8
	return r, g, b
end)
local sceneCopy = writeBmp(fixtures .. '/a-copy.bmp', 96, function(x, y)
	local r = (x * 2) % 256
	local g = (y * 2) % 256
	local b = ((x + y) % 32) * 8
	return r, g, b
end)
local sceneOther = writeBmp(fixtures .. '/other.bmp', 96, function(x, y)
	-- Hard diagonal stripes, nothing like the smooth gradient above.
	return ((x + y) % 12 < 6) and 255 or 0, 0, ((x * y) % 7 < 3) and 255 or 0
end)

-- MARK: - FsJson

local FsJson = require 'FsJson'

local function testJson()
	local awkward = {
		path = '/tmp/it\'s "here"/\194\169 \\ backslash.jpg',
		id = 'a"b\\c',
		tab = 'line\nbreak\ttab',
	}
	local back = FsJson.decode(FsJson.encode(awkward))
	check(back and back.path == awkward.path, 'json round-trips quotes, backslashes and UTF-8 in paths')
	check(back and back.tab == awkward.tab, 'json round-trips control characters')

	check(FsJson.decode('2.9381551939877681e-05') == 2.9381551939877681e-05,
		'json reads the exponent-form distances the helper emits')
	check(#FsJson.decode('[1,null,3]') == 3, 'a null does not shorten an array')
	check(select(1, FsJson.decode('{"a":1,}')) == nil, 'a trailing comma is rejected')
	check(select(1, FsJson.decode('')) == nil, 'empty input is rejected without raising')
	check(select(1, FsJson.decode('{"a":1} trailing')) == nil, 'trailing input is rejected')
	check(FsJson.decode('"\\u00e9"') == '\195\169', 'json decodes a \\u escape as UTF-8')
	check(FsJson.encode({ 1, 2, 3 }) == '[1,2,3]', 'a 1..n table encodes as an array')
	check(FsJson.encode({}) == '[]', 'an empty table encodes as an array')
end

-- MARK: - FsGrouping

local FsGrouping = require 'FsGrouping'

local function testGrouping()
	check(FsGrouping.orientationBucket(4000, 3000) == 'landscape', 'a 4:3 frame is landscape')
	check(FsGrouping.orientationBucket(3000, 4000) == 'portrait', 'a 3:4 frame is portrait')
	check(FsGrouping.orientationBucket(1000, 1000) == 'square', 'a 1:1 frame is square')
	check(FsGrouping.orientationBucket(nil, nil) == 'square', 'missing dimensions fall back to square')

	check(FsGrouping.cameraKey('Apple', 'iPhone 15 Pro', 'back triple camera')
		== 'Apple · iPhone 15 Pro · back triple camera', 'the camera key joins make, model and lens')
	check(FsGrouping.cameraKey(nil, '  ', nil) == '', 'a blank camera key is empty, not whitespace')

	local records = {
		{ id = 'c', time = 100, orientation = 'landscape', camera = 'X' },
		{ id = 'a', time = 0, orientation = 'landscape', camera = 'X' },
		{ id = 'b', time = 5, orientation = 'landscape', camera = 'X' },
	}
	local groups = FsGrouping.candidates(records, { timeWindow = 12, requireSameCamera = true })
	check(#groups == 1 and #groups[1] == 2, 'an out-of-order pair 5s apart groups; the 100s frame does not')
	check(groups[1][1].id == 'a' and groups[1][2].id == 'b', 'a group comes back in capture order')

	-- A run of frames each within the window of the previous one stays one group,
	-- even though the first and last are far apart. This is the app's behaviour.
	local chain = {}
	for i = 0, 9 do chain[#chain + 1] = { id = i, time = i * 10, orientation = 'landscape', camera = 'X' } end
	local chained = FsGrouping.candidates(chain, { timeWindow = 12, requireSameCamera = true })
	check(#chained == 1 and #chained[1] == 10, 'a continuous run is one group, not cut every window')

	local mixed = {
		{ id = 'p', time = 0, orientation = 'portrait', camera = 'X' },
		{ id = 'l', time = 1, orientation = 'landscape', camera = 'X' },
	}
	check(#FsGrouping.candidates(mixed, { timeWindow = 12, requireSameCamera = true }) == 0,
		'a portrait and a landscape frame do not group')

	local cameras = {
		{ id = 'one', time = 0, orientation = 'landscape', camera = 'Canon' },
		{ id = 'two', time = 1, orientation = 'landscape', camera = 'Nikon' },
	}
	check(#FsGrouping.candidates(cameras, { timeWindow = 12, requireSameCamera = true }) == 0,
		'two cameras do not group when the camera gate is on')
	check(#FsGrouping.candidates(cameras, { timeWindow = 12, requireSameCamera = false }) == 1,
		'…and do when it is off')

	local batches = FsGrouping.batch({ 1, 2, 3, 4, 5 }, 2)
	check(#batches == 3 and #batches[3] == 1, 'batching splits 5 groups into 2+2+1')
end

-- MARK: - FsSettings

local FsSettings = require 'FsSettings'

local function testSettings()
	local prefs = FsSettings.prefs()
	check(prefs.timeWindow == 12, 'defaults are filled in on first read')
	check(prefs.similarityThreshold == 0.5, 'the similarity default matches the app')
	check(prefs.rejectOthers == false, 'rejecting duplicates is off by default')

	prefs.timeWindow = 99
	check(FsSettings.prefs().timeWindow == 99, 'a set preference is not overwritten by the default')
	FsSettings.reset()
	check(FsSettings.prefs().timeWindow == 12, 'reset puts the defaults back')

	check(FsSettings.number('abc', 12) == 12, 'a non-numeric field falls back')
	check(FsSettings.number('0.005', 0.5, 0.01, 2) == 0.01, 'a too-small value is clamped up')
	check(FsSettings.number('900', 0.5, 0.01, 2) == 2, 'a too-large value is clamped down')
	check(FsSettings.number('1.5', 0.5, 0.01, 2) == 1.5, 'a valid string is read as a number')
end

-- MARK: - FsScorer, against the real binary

local FsScorer = require 'FsScorer'

local function testScorerPlumbing()
	local ok, message = FsScorer.checkAvailable()
	check(ok, 'the helper is found inside the bundle: ' .. tostring(message))
	check(FsScorer.binaryPath():match('bin/macOS/featured%-scorer$') ~= nil,
		'the helper path resolves into the bundle')

	local version = FsScorer.version()
	check(version ~= nil and version:match('^%d+%.%d+%.%d+$') ~= nil,
		'the helper reports a version: ' .. tostring(version))
end

local function testScorerGroupsIdenticalFrames()
	local result, message = FsScorer.score({
		{ photos = { { id = 'a', path = sceneA }, { id = 'copy', path = sceneCopy } } },
	}, { similarityThreshold = 0.5, analysisSize = 256 })

	check(result ~= nil, 'the helper returns a result: ' .. tostring(message))
	if not result then return end
	check(#result.stacks == 1, 'two identical frames become one stack')
	if #result.stacks ~= 1 then return end

	local items = result.stacks[1].items
	check(#items == 2, 'the stack holds both frames')
	check(items[1].distanceToTop == nil, 'the pick has no distance to itself')
	check(items[2].distanceToTop == 0, 'an identical frame sits at distance 0 from the pick')
	check(type(items[1].score) == 'number' and items[1].score >= items[2].score,
		'items come back ranked best first')
	check(type(items[1].breakdown) == 'table' and items[1].breakdown.aesthetic ~= nil,
		'each item carries a score breakdown')
end

local function testScorerSeparatesDifferentFrames()
	local result = FsScorer.score({
		{ photos = { { id = 'a', path = sceneA }, { id = 'other', path = sceneOther } } },
	}, { similarityThreshold = 0.5, analysisSize = 256 })
	check(result ~= nil and #result.stacks == 0,
		'two unrelated frames do not stack at the default threshold')
end

local function testScorerHonoursTheThreshold()
	-- Identical frames sit at distance 0, so nothing but a negative threshold can
	-- separate them. That makes this an exact test that the knob is plumbed
	-- through rather than one that depends on what Vision thinks of a fixture.
	local result = FsScorer.score({
		{ photos = { { id = 'a', path = sceneA }, { id = 'copy', path = sceneCopy } } },
	}, { similarityThreshold = -1, analysisSize = 256 })
	check(result ~= nil and #result.stacks == 0, 'the similarity threshold reaches the helper')
end

local function testScorerReportsUnreadableFiles()
	local result = FsScorer.score({
		{ photos = {
			{ id = 'a', path = sceneA },
			{ id = 'copy', path = sceneCopy },
			{ id = 'ghost', path = workRoot .. '/not-here.jpg' },
		} },
	}, { similarityThreshold = 0.5, analysisSize = 256 })

	check(result ~= nil and #result.unreadable == 1 and result.unreadable[1] == 'ghost',
		'a missing file is reported, not fatal')
	check(result ~= nil and #result.stacks == 1, 'the readable frames still stack')
end

local function testScorerQuotesAwkwardPaths()
	local awkward = fixtures .. "/it's a \"photo\" $HOME `x`.bmp"
	-- Copied in Lua, not through the shell: os.execute with string.format('%q')
	-- is Lua's escaping, not the shell's, so `$HOME` and the backticks would be
	-- expanded on the way and the fixture would never be written. Only FsScorer's
	-- quoting is under test here.
	local source = assert(io.open(sceneA, 'rb'))
	local target = assert(io.open(awkward, 'wb'))
	target:write(source:read('a'))
	source:close()
	target:close()
	local result = FsScorer.score({
		{ photos = { { id = 'a', path = sceneA }, { id = 'awkward', path = awkward } } },
	}, { similarityThreshold = 0.5, analysisSize = 256 })
	check(result ~= nil and #result.stacks == 1 and #result.unreadable == 0,
		'quotes, spaces and shell metacharacters in a path survive the command line')
end

local function testScorerFailureIsReported()
	-- Point the bundle at a binary that is not one, and check the caller gets a
	-- message rather than an exception or a silent empty result.
	local broken = workRoot .. '/broken.lrdevplugin'
	os.execute(string.format('rm -rf %q && mkdir -p %q/bin/macOS', broken, broken))
	os.execute(string.format('printf "not a binary" > %q/bin/macOS/featured-scorer', broken))
	os.execute(string.format('chmod +x %q/bin/macOS/featured-scorer', broken))

	local realPath = _PLUGIN.path
	_PLUGIN.path = broken
	FsScorer.forget()
	local result, message = FsScorer.score({
		{ photos = { { id = 'a', path = sceneA }, { id = 'b', path = sceneCopy } } },
	}, { similarityThreshold = 0.5, analysisSize = 256 })
	_PLUGIN.path = realPath
	FsScorer.forget()

	check(result == nil and type(message) == 'string' and message ~= '',
		'a helper that will not run produces a message: ' .. tostring(message))
end

local function testScorerNeedsATask()
	stubs.inTask = false
	local ok = pcall(FsScorer.score, {
		{ photos = { { id = 'a', path = sceneA }, { id = 'b', path = sceneCopy } } },
	}, { similarityThreshold = 0.5, analysisSize = 256 })
	stubs.inTask = true
	check(not ok, 'shelling out outside a task raises, the way Lightroom would')
end

-- MARK: - Folder mode
--
-- The helper's standalone entry point. It does its own gating from EXIF rather
-- than being handed groups, so this is the only test that covers the Swift half
-- of the time/orientation/camera pass. The BMP fixtures carry no EXIF, so every
-- frame falls back to its file date and lands in one time cluster — which is
-- what makes the counts below exact.

local function runScorer(argline)
	local outPath = workRoot .. '/folder-out.json'
	local command = string.format('%q %s > %q 2>/dev/null',
		pluginPath .. '/bin/macOS/featured-scorer', argline, outPath)
	local exitCode = os.execute(command)
	local file = io.open(outPath, 'rb')
	local text = file and file:read('a') or ''
	if file then file:close() end
	os.remove(outPath)
	return exitCode, text
end

local function testFolderMode()
	local folder = workRoot .. '/folder'
	local nested = folder .. '/nested'
	os.execute(string.format('rm -rf %q && mkdir -p %q', folder, nested))

	local function copy(from, to)
		local source = assert(io.open(from, 'rb'))
		local target = assert(io.open(to, 'wb'))
		target:write(source:read('a'))
		source:close()
		target:close()
	end
	copy(sceneA, folder .. '/a.bmp')
	copy(sceneCopy, folder .. '/a-copy.bmp')
	copy(sceneOther, folder .. '/other.bmp')
	copy(sceneA, nested .. '/a-nested.bmp')

	local _, text = runScorer(string.format('--folder %q --json', folder))
	local result = FsJson.decode(text)
	check(result ~= nil and result.stacks ~= nil, 'folder mode emits parsable JSON')
	if not result or not result.stacks then return end

	check(#result.stacks == 1, 'the three identical frames make one stack, the odd one out is dropped')
	if #result.stacks == 1 then
		check(#result.stacks[1].items == 3, 'the nested copy is included by default (recursive)')
	end

	local _, shallow = runScorer(string.format('--folder %q --json --no-recurse', folder))
	local shallowResult = FsJson.decode(shallow)
	check(shallowResult and #shallowResult.stacks == 1
		and #shallowResult.stacks[1].items == 2, '--no-recurse leaves the nested copy out')

	local _, strict = runScorer(string.format('--folder %q --json --threshold -1', folder))
	local strictResult = FsJson.decode(strict)
	check(strictResult and #strictResult.stacks == 0, '--threshold reaches the folder pipeline')

	local _, report = runScorer(string.format('--folder %q', folder))
	check(report:match('Scanned 4 images') ~= nil, 'the human report counts every image found')
	check(report:match('★') ~= nil, 'the human report marks the pick')

	local code = runScorer('--folder /nope/definitely/missing')
	check(code ~= true and code ~= 0, 'a missing folder exits non-zero')
end

-- MARK: - FsEngine's catalog read

local FsEngine = require 'FsEngine'

local function testReadRecords()
	local one, two, video, undated = {}, {}, {}, {}
	stubs.catalogData.photos = { one, two, video, undated }
	stubs.catalogData.raw = {
		[one] = { uuid = 'u1', dateTimeOriginal = 1000, croppedDimensions = { width = 4000, height = 3000 } },
		[two] = { uuid = 'u2', dateTimeOriginal = 1004, croppedDimensions = { width = 4000, height = 3000 } },
		[video] = { uuid = 'u3', dateTimeOriginal = 1002, isVideo = true },
		[undated] = { uuid = 'u4', dimensions = { width = 100, height = 100 } },
	}
	stubs.catalogData.formatted = {
		[one] = { cameraMake = 'Apple', cameraModel = 'iPhone 15 Pro' },
		[two] = { cameraMake = 'Apple', cameraModel = 'iPhone 15 Pro' },
	}

	local records, skipped = FsEngine.readRecords(stubs.catalogData.photos,
		{ requireSameCamera = true })
	check(#records == 2, 'videos and undated photos are left out of the records')
	check(skipped == 2, 'and are counted as skipped')
	check(records[1].orientation == 'landscape', 'orientation comes from the cropped dimensions')
	check(records[1].camera == 'Apple · iPhone 15 Pro', 'the camera key is built from formatted metadata')

	local groups = FsGrouping.candidates(records, { timeWindow = 12, requireSameCamera = true })
	check(#groups == 1 and #groups[1] == 2, 'the two stills 4s apart make one candidate group')

	-- A photo with no capture time cannot be time-clustered, so it must never
	-- reach the renderer; that is what the skip above is protecting.
	check(FsEngine.targetPhotos() ~= nil, 'target photos come back from the catalog')
end

-- MARK: - Views build outside a task

local function testDialogsBuildOutsideATask()
	local FsReviewDialog = require 'FsReviewDialog'
	local PluginInfoProvider = require 'PluginInfoProvider'

	stubs.inTask = false
	local ok, err = pcall(function()
		local sections = PluginInfoProvider.sectionsForTopOfDialog(stubs.viewFactory(), {})
		assert(#sections == 3, 'expected three panel sections, got ' .. tostring(#sections))
	end)
	stubs.inTask = true
	check(ok, 'the Plug-in Manager panel builds on the main thread: ' .. tostring(err))

	stubs.lastDialog = nil
	local answer = FsReviewDialog.show(
		{ stacks = {}, scanned = 12, skipped = 0, unreadable = 0 },
		{ actionVerb = 'Apply', applyDescription = 'x' })
	check(answer == 'ok' and stubs.lastDialog ~= nil,
		'an empty result explains itself instead of showing an empty dialog')

	stubs.modalAnswer = 'ok'
	local photo = {}
	local result = {
		scanned = 2, skipped = 0, unreadable = 1,
		stacks = { { items = {
			{ photo = photo, id = 'u1', score = 0.74, breakdown = { aesthetic = 0.74, faceCount = 2, eyesOpen = 1 } },
			{ photo = photo, id = 'u2', score = 0.70, distanceToTop = 0.031, breakdown = { aesthetic = 0.7, faceCount = 2 } },
		} } },
	}
	local ok2, err2 = pcall(FsReviewDialog.show, result,
		{ actionVerb = 'Apply', applyDescription = 'x' })
	check(ok2, 'the review dialog builds a stack row: ' .. tostring(err2))
end

testJson()
testGrouping()
testSettings()
testScorerPlumbing()
testScorerGroupsIdenticalFrames()
testScorerSeparatesDifferentFrames()
testScorerHonoursTheThreshold()
testScorerReportsUnreadableFiles()
testScorerQuotesAwkwardPaths()
testScorerFailureIsReported()
testScorerNeedsATask()
testFolderMode()
testReadRecords()
testDialogsBuildOutsideATask()

if failures > 0 then
	io.stderr:write(string.format('%d check(s) failed\n', failures))
	os.exit(1)
end
print('all plug-in checks passed')
