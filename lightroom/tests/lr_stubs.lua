--[[----------------------------------------------------------------------------
lr_stubs.lua — just enough of the Lightroom Classic SDK to run the plug-in's
non-UI modules under a plain Lua interpreter.

This is a test harness, not an emulator: it covers the Lr* calls FsJson,
FsGrouping, FsSettings, FsScorer and FsEngine make, so their behaviour
(grouping, shell quoting, JSON handling, catalog reads, error paths) can be
checked against the real native helper without Lightroom.

Adapted from the same harness in the JPG-HDR plug-in.
------------------------------------------------------------------------------]]

local stubs = {}

local modules = {}

--- LOC '$$$/Some/Key=Text with ^1' -> 'Text with ^1', substituting arguments.
function LOC(text, ...)
	local out = tostring(text):gsub('^%$%$%$/[%w/_%.]+=', '')
	local args = { ... }
	for i = 1, #args do
		out = out:gsub('%^' .. i, tostring(args[i]))
	end
	return out
end

local function pathSeparator() return '/' end

modules.LrPathUtils = {
	child = function(dir, name)
		if dir:sub(-1) == pathSeparator() then return dir .. name end
		return dir .. pathSeparator() .. name
	end,
	leafName = function(path) return (path:match('[^/\\]+$')) or path end,
	parent = function(path) return (path:match('^(.*)[/\\][^/\\]*$')) end,
	extension = function(path) return (path:match('%.([^%.\\/]+)$')) or '' end,
	replaceExtension = function(path, ext)
		return (path:gsub('%.[^%.\\/]+$', '')) .. '.' .. ext
	end,
	getStandardFilePath = function(which)
		if which == 'temp' then return stubs.tempDir or os.getenv('TMPDIR') or '/tmp' end
		return os.getenv('HOME') or '/tmp'
	end,
}

modules.LrFileUtils = {
	exists = function(path)
		local f = io.open(path, 'rb')
		if f then f:close() return 'file' end
		-- A directory opens on some systems and not others; ask the shell.
		if os.execute(string.format('test -d %q', path)) == true then return 'directory' end
		return false
	end,
	readFile = function(path)
		local f = io.open(path, 'rb')
		if not f then error('cannot read ' .. path) end
		local contents = f:read('a')
		f:close()
		return contents
	end,
	delete = function(path)
		if os.remove(path) then return true end
		return os.execute(string.format('rm -rf %q', path)) == true
	end,
	createAllDirectories = function(path)
		os.execute(string.format('mkdir -p %q', path))
		return true
	end,
}

-- Lightroom only lets you block inside a task; anywhere else — dialog
-- construction, a binding, a button action — a yielding call raises. The stub
-- raises the same way, so a module that shells out while building UI fails here
-- instead of in the Plug-in Manager's error log.
stubs.inTask = true

modules.LrTasks = {
	execute = function(command)
		if not stubs.inTask then
			error('We can only wait from within a task', 0)
		end
		local ok, _, code = os.execute(command)
		if ok == true then return 0 end
		if type(ok) == 'number' then return ok end
		return code or 1
	end,
	canYield = function() return stubs.inTask == true end,
	startAsyncTask = function(fn)
		local wasInTask = stubs.inTask
		stubs.inTask = true
		local ok, err = pcall(fn)
		stubs.inTask = wasInTask
		if not ok then error(err, 0) end
	end,
	yield = function() end,
	sleep = function() end,
}

local logger = {
	enable = function() end,
	disable = function() end,
	info = function(_, m) if stubs.verbose then print('[log] ' .. tostring(m)) end end,
	warn = function(_, m) if stubs.verbose then print('[warn] ' .. tostring(m)) end end,
	error = function(_, m) if stubs.verbose then print('[err] ' .. tostring(m)) end end,
}
modules.LrLogger = setmetatable({}, { __call = function() return logger end })

stubs.prefs = {}
modules.LrPrefs = { prefsForPlugin = function() return stubs.prefs end }

modules.LrDialogs = {
	message = function(title, detail) stubs.lastDialog = { title, detail } end,
	confirm = function() return stubs.confirmAnswer or 'cancel' end,
	showBezel = function(text) stubs.lastBezel = text end,
	presentModalDialog = function(args)
		stubs.lastModal = args
		return stubs.modalAnswer or 'cancel'
	end,
	showModalProgressDialog = function() return stubs.progressScope() end,
}

--- A progress scope that records what it was told and can pretend to be cancelled.
function stubs.progressScope()
	return {
		setPortionComplete = function(_, done, total) stubs.progress = { done, total } end,
		setCaption = function(_, text) stubs.progressCaption = text end,
		isCanceled = function() return stubs.canceled == true end,
		done = function() stubs.progressDone = true end,
	}
end

modules.LrFunctionContext = {
	callWithContext = function(_, fn) return fn({ addCleanupHandler = function() end }) end,
	postAsyncTaskWithContext = function(_, fn) return fn({ addCleanupHandler = function() end }) end,
}

modules.LrErrors = {
	throwUserError = function(message) error(message, 0) end,
}

modules.LrColor = setmetatable({}, { __call = function() return {} end })

modules.LrView = {
	bind = function(spec) return spec end,
	share = function(name) return name end,
	osFactory = function() return stubs.viewFactory() end,
}

modules.LrBinding = {
	makePropertyTable = function() return {} end,
}

--- A stand-in for the LrView factory the dialog builders are handed. Every
--- control is a function of (self, args) that just returns its arguments, which
--- is enough to run the builders and see what they do while assembling a view.
function stubs.viewFactory()
	return setmetatable({}, {
		__index = function(_, name)
			if name == 'control_spacing' then return function() return 8 end end
			return function(_, args) return args or {} end
		end,
	})
end

-- MARK: - Catalog
--
-- stubs.catalog is a plain table the tests fill in; the photos are whatever the
-- test says they are, since nothing here dereferences an LrPhoto beyond using
-- it as a table key.

stubs.catalogData = { raw = {}, formatted = {}, photos = {}, byUuid = {} }

local catalog = {
	getTargetPhotos = function() return stubs.catalogData.photos end,
	batchGetRawMetadata = function(_, photos, keys)
		local out = {}
		for _, photo in ipairs(photos) do
			local source = stubs.catalogData.raw[photo] or {}
			local picked = {}
			for _, key in ipairs(keys) do picked[key] = source[key] end
			out[photo] = picked
		end
		return out
	end,
	batchGetFormattedMetadata = function(_, photos, keys)
		local out = {}
		for _, photo in ipairs(photos) do
			local source = stubs.catalogData.formatted[photo] or {}
			local picked = {}
			for _, key in ipairs(keys) do picked[key] = source[key] end
			out[photo] = picked
		end
		return out
	end,
	findPhotoByUuid = function(_, uuid) return stubs.catalogData.byUuid[uuid] end,
	setSelectedPhotos = function(_, active, photos)
		stubs.selection = { active = active, photos = photos }
	end,
	withWriteAccessDo = function(_, _, fn) return fn() end,
	withPrivateWriteAccessDo = function(_, fn) return fn() end,
	createCollectionSet = function(_, name) return { name = name, getChildCollections = function() return {} end } end,
	createCollection = function(_, name)
		return {
			name = name,
			removeAllPhotos = function() end,
			addPhotos = function(_, photos) stubs.collected = photos end,
			delete = function() end,
		}
	end,
}

modules.LrApplication = {
	activeCatalog = function() return catalog end,
}

modules.LrExportSession = setmetatable({}, {
	__call = function(_, args)
		stubs.exportSettings = args.exportSettings
		return {
			renditions = function()
				local index = 0
				return function()
					index = index + 1
					local photo = args.photosToExport[index]
					if not photo then return nil end
					return index, {
						photo = photo,
						waitForRender = function()
							local path = stubs.renditionPaths and stubs.renditionPaths[photo]
							if path then return true, path end
							return false, 'no rendition in the test harness'
						end,
					}
				end
			end,
		}
	end,
})

function import(name)
	local m = modules[name]
	if m == nil then error('lr_stubs: no stub for ' .. tostring(name)) end
	return m
end

--- Installs the globals a plug-in module expects and points require at the
--- plug-in directory.
function stubs.install(pluginPath)
	_PLUGIN = { path = pluginPath, id = 'com.akvaithi.lightroom.featuredstacks' }
	WIN_ENV = false
	MAC_ENV = true
	package.path = pluginPath .. '/?.lua;' .. package.path
end

stubs.modules = modules
return stubs
