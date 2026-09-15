--[[----------------------------------------------------------------------------
FsScorer.lua — locating and running the bundled native helper.

Everything platform specific lives here: which binary to use, how to quote a
command line for the shell Lightroom hands to LrTasks.execute, and how to get
the helper's stdout and stderr back out of it.

The helper is macOS only, because the analysis is Vision's. On Windows the
plug-in still loads and still groups by capture time, orientation and camera —
it just cannot rank frames or tell near-identical ones apart, and the menu
command says so rather than failing halfway through.
------------------------------------------------------------------------------]]

local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local FsJson = require 'FsJson'
local FsLogger = require 'FsLogger'

local FsScorer = {}

local isWindows = WIN_ENV == true

-- Lightroom builds dialog sections on the main thread, where any yielding call
-- fails with "We can only wait from within a task". LrTasks.execute yields, so
-- everything that shells out has to check this first and let the UI fill itself
-- in from a task instead.
local function canYield()
	return LrTasks.canYield ~= nil and LrTasks.canYield() == true
end

--- Absolute path of the platform binary inside the plug-in bundle.
function FsScorer.binaryPath()
	local dir = LrPathUtils.child(_PLUGIN.path, 'bin')
	if isWindows then
		return LrPathUtils.child(LrPathUtils.child(dir, 'windows'), 'featured-scorer.exe')
	end
	return LrPathUtils.child(LrPathUtils.child(dir, 'macOS'), 'featured-scorer')
end

local executableChecked = false

-- Forward declaration: checkAvailable quotes a path before `quote` is defined.
-- It must stay a local — Lightroom shares globals across a plug-in's files.
local quote

--- Confirms the helper is present and runnable. Returns (ok, message).
function FsScorer.checkAvailable()
	if isWindows then
		return false, LOC '$$$/FeaturedStacks/NoWindows=Scoring needs Apple\'s Vision framework, so it is macOS only.'
	end
	local path = FsScorer.binaryPath()
	if not LrFileUtils.exists(path) then
		return false, LOC('$$$/FeaturedStacks/NoBinary=The scoring helper is missing from the plug-in: ^1', path)
	end
	if not executableChecked and canYield() then
		-- Zip archives and some download paths drop the executable bit. This
		-- shells out, so it is skipped outside a task; every path that actually
		-- runs the helper is inside one, and gets it done there.
		--
		-- Note this quotes with `quote`, not string.format('%q'): %q is Lua's
		-- escaping and produces double quotes, inside which a plug-in installed
		-- under a folder containing `$` or a backtick would be expanded by the
		-- shell rather than passed through.
		LrTasks.execute('chmod +x ' .. quote(path))
		executableChecked = true
	end
	return true
end

quote = function(value)
	if isWindows then
		return '"' .. tostring(value):gsub('"', '') .. '"'
	end
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function readAll(path)
	if not LrFileUtils.exists(path) then return '' end
	local ok, contents = pcall(LrFileUtils.readFile, path)
	return ok and contents or ''
end

local function tempPath(name)
	return LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), name)
end

--- Runs the helper over one batch of groups.
---
--- @param groups table   array of { photos = { { id = , path = }, ... } }
--- @param options table  { similarityThreshold, analysisSize }
--- @return table|nil result, string|nil errorMessage
function FsScorer.score(groups, options)
	local ok, message = FsScorer.checkAvailable()
	if not ok then return nil, message end
	if #groups == 0 then return { stacks = {}, unreadable = {} } end

	local stamp = tostring(os.time()) .. '-' .. tostring(math.random(100000, 999999))
	local jobPath = tempPath('featured-stacks-job-' .. stamp .. '.json')
	local outPath = tempPath('featured-stacks-out-' .. stamp .. '.json')
	local errPath = tempPath('featured-stacks-err-' .. stamp .. '.txt')

	local job = {
		similarityThreshold = options.similarityThreshold,
		analysisSize = options.analysisSize,
		groups = groups,
	}

	-- The job goes through a file rather than an argument list: a batch is
	-- hundreds of absolute paths and would blow past the command-line limit.
	local handle, openError = io.open(jobPath, 'wb')
	if not handle then
		return nil, LOC('$$$/FeaturedStacks/NoTemp=Could not write a temporary file: ^1',
			tostring(openError))
	end
	handle:write(FsJson.encode(job))
	handle:close()

	local command = string.format('%s < %s > %s 2> %s',
		quote(FsScorer.binaryPath()), quote(jobPath), quote(outPath), quote(errPath))
	FsLogger.info('running: ' .. command)

	local exitCode = LrTasks.execute(command)
	local out = readAll(outPath)
	local err = readAll(errPath)
	LrFileUtils.delete(jobPath)
	LrFileUtils.delete(outPath)
	LrFileUtils.delete(errPath)

	if exitCode ~= 0 then
		local detail = err:match('error:%s*(.-)%s*$')
		if detail == nil or detail == '' then
			detail = LOC('$$$/FeaturedStacks/ExitCode=the scoring helper exited with code ^1',
				tostring(exitCode))
		end
		FsLogger.error('helper failed: ' .. tostring(detail))
		return nil, detail
	end

	local result, decodeError = FsJson.decode(out)
	if not result then
		FsLogger.error('unparsable helper output: ' .. tostring(decodeError))
		return nil, LOC('$$$/FeaturedStacks/BadOutput=The scoring helper returned something unreadable: ^1',
			tostring(decodeError))
	end

	result.stacks = result.stacks or {}
	result.unreadable = result.unreadable or {}
	return result
end

local cachedVersion, versionQueried = nil, false

--- Version of the bundled helper, or nil if it is missing, would not run, or has
--- not been asked yet. Running it yields, so a caller outside a task gets nil
--- rather than an error: dialogs show a placeholder and call this again from
--- LrTasks.startAsyncTask. The answer is cached, so that is one subprocess per
--- session.
function FsScorer.version()
	if versionQueried then return cachedVersion end
	local ok = FsScorer.checkAvailable()
	if not ok or not canYield() then return nil end

	local path = tempPath('featured-scorer-version.txt')
	local command = string.format('%s --version > %s 2>&1',
		quote(FsScorer.binaryPath()), quote(path))
	local exitCode = LrTasks.execute(command)
	local text = readAll(path)
	LrFileUtils.delete(path)

	versionQueried = true
	cachedVersion = exitCode == 0 and (text:gsub('%s+$', '')) or nil
	return cachedVersion
end

--- Drops what was cached about the helper, so the next call re-examines it. The
--- Plug-in Manager's test button uses this after the user has fixed something —
--- a quarantine flag, a missing file — that we already gave up on.
function FsScorer.forget()
	cachedVersion, versionQueried = nil, false
	executableChecked = false
end

return FsScorer
