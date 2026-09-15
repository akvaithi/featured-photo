--[[----------------------------------------------------------------------------
FsLogger.lua — logging.

Off by default; the Plug-in Manager panel turns it on. The log lands in
~/Documents/LrClassicLogs/FeaturedStacks.log.
------------------------------------------------------------------------------]]

local LrLogger = import 'LrLogger'

local logger = LrLogger('FeaturedStacks')
local enabled = false

local FsLogger = {}

--- Routes output to the log file, or silences it. Called from the settings panel.
function FsLogger.setEnabled(value)
	enabled = value and true or false
	if enabled then
		logger:enable('logfile')
	else
		logger:disable()
	end
end

function FsLogger.isEnabled()
	return enabled
end

function FsLogger.info(message)
	if enabled then logger:info(message) end
end

function FsLogger.warn(message)
	if enabled then logger:warn(message) end
end

function FsLogger.error(message)
	-- Errors are always recorded: when a user reports a failure, this is the
	-- only trace of it, and asking them to reproduce with logging on loses it.
	logger:enable('logfile')
	logger:error(message)
	if not enabled then logger:disable() end
end

return FsLogger
