--[[----------------------------------------------------------------------------
FsJson.lua — JSON for talking to featured-scorer.

Lightroom's SDK ships no JSON module, and both ends of this conversation are
ours, so this is a small complete parser rather than a pattern-matching hack:
the scorer emits exponent-form numbers (a feature-print distance of 2.9e-05 is
normal for two frames of the same shot) and file paths that can hold quotes and
backslashes, neither of which survives a `gmatch` approach.

Lightroom runs Lua 5.1, so nothing here uses 5.2+ syntax.
------------------------------------------------------------------------------]]

local FsJson = {}

-- MARK: - Encoding

local escapes = {
	['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
	['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escapeString(value)
	local out = value:gsub('[%c"\\]', function(char)
		return escapes[char] or string.format('\\u%04x', char:byte())
	end)
	return '"' .. out .. '"'
end

local function isArray(value)
	local count = 0
	for key in pairs(value) do
		if type(key) ~= 'number' then return false end
		count = count + 1
	end
	return count == #value
end

local encodeValue

encodeValue = function(value, out)
	local kind = type(value)
	if value == nil or value == FsJson.null then
		out[#out + 1] = 'null'
	elseif kind == 'boolean' then
		out[#out + 1] = value and 'true' or 'false'
	elseif kind == 'number' then
		-- %.17g round-trips a double exactly; Lua's tostring would not.
		if value ~= value or value == math.huge or value == -math.huge then
			out[#out + 1] = 'null' -- JSON has no NaN or Infinity
		else
			out[#out + 1] = string.format('%.17g', value)
		end
	elseif kind == 'string' then
		out[#out + 1] = escapeString(value)
	elseif kind == 'table' then
		if isArray(value) then
			out[#out + 1] = '['
			for i = 1, #value do
				if i > 1 then out[#out + 1] = ',' end
				encodeValue(value[i], out)
			end
			out[#out + 1] = ']'
		else
			out[#out + 1] = '{'
			local first = true
			for key, item in pairs(value) do
				if not first then out[#out + 1] = ',' end
				first = false
				out[#out + 1] = escapeString(tostring(key))
				out[#out + 1] = ':'
				encodeValue(item, out)
			end
			out[#out + 1] = '}'
		end
	else
		error('cannot encode a ' .. kind .. ' as JSON')
	end
end

--- Serialises a Lua value. Tables with purely 1..n integer keys become arrays.
function FsJson.encode(value)
	local out = {}
	encodeValue(value, out)
	return table.concat(out)
end

-- MARK: - Decoding

-- Sentinel for JSON null, so a null inside an array does not shorten it.
FsJson.null = setmetatable({}, { __tostring = function() return 'null' end })

local function skipWhitespace(text, pos)
	local _, stop = text:find('^[ \t\r\n]*', pos)
	return stop + 1
end

local parseValue

local function parseError(text, pos, message)
	local line = 1
	for _ in text:sub(1, pos):gmatch('\n') do line = line + 1 end
	error(string.format('JSON: %s at line %d (offset %d)', message, line, pos), 0)
end

local unescapes = {
	['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
	f = '\f', n = '\n', r = '\r', t = '\t',
}

--- Encodes a Unicode code point as UTF-8. Lightroom's Lua has no utf8 library.
local function utf8Encode(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
	elseif code < 0x10000 then
		return string.char(0xE0 + math.floor(code / 0x1000),
			0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
	end
	return string.char(0xF0 + math.floor(code / 0x40000),
		0x80 + math.floor(code / 0x1000) % 0x40,
		0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function parseString(text, pos)
	pos = pos + 1 -- opening quote
	local parts = {}
	while true do
		local char = text:sub(pos, pos)
		if char == '' then parseError(text, pos, 'unterminated string') end
		if char == '"' then
			return table.concat(parts), pos + 1
		elseif char == '\\' then
			local code = text:sub(pos + 1, pos + 1)
			if code == 'u' then
				local hex = text:sub(pos + 2, pos + 5)
				local value = tonumber(hex, 16)
				if not value then parseError(text, pos, 'bad \\u escape') end
				pos = pos + 6
				-- Surrogate pair: the scorer never emits one, but a path could.
				if value >= 0xD800 and value <= 0xDBFF and text:sub(pos, pos + 1) == '\\u' then
					local low = tonumber(text:sub(pos + 2, pos + 5), 16)
					if low and low >= 0xDC00 and low <= 0xDFFF then
						value = 0x10000 + (value - 0xD800) * 0x400 + (low - 0xDC00)
						pos = pos + 6
					end
				end
				parts[#parts + 1] = utf8Encode(value)
			else
				local literal = unescapes[code]
				if not literal then parseError(text, pos, 'bad escape \\' .. code) end
				parts[#parts + 1] = literal
				pos = pos + 2
			end
		else
			-- Take the whole run up to the next quote or backslash in one go.
			local stop = text:find('["\\]', pos)
			if not stop then parseError(text, pos, 'unterminated string') end
			parts[#parts + 1] = text:sub(pos, stop - 1)
			pos = stop
		end
	end
end

parseValue = function(text, pos)
	pos = skipWhitespace(text, pos)
	local char = text:sub(pos, pos)

	if char == '{' then
		local object = {}
		pos = skipWhitespace(text, pos + 1)
		if text:sub(pos, pos) == '}' then return object, pos + 1 end
		while true do
			pos = skipWhitespace(text, pos)
			if text:sub(pos, pos) ~= '"' then parseError(text, pos, 'expected a key') end
			local key
			key, pos = parseString(text, pos)
			pos = skipWhitespace(text, pos)
			if text:sub(pos, pos) ~= ':' then parseError(text, pos, "expected ':'") end
			object[key], pos = parseValue(text, pos + 1)
			pos = skipWhitespace(text, pos)
			local delimiter = text:sub(pos, pos)
			if delimiter == ',' then pos = pos + 1
			elseif delimiter == '}' then return object, pos + 1
			else parseError(text, pos, "expected ',' or '}'") end
		end

	elseif char == '[' then
		local array = {}
		pos = skipWhitespace(text, pos + 1)
		if text:sub(pos, pos) == ']' then return array, pos + 1 end
		while true do
			array[#array + 1], pos = parseValue(text, pos)
			pos = skipWhitespace(text, pos)
			local delimiter = text:sub(pos, pos)
			if delimiter == ',' then pos = pos + 1
			elseif delimiter == ']' then return array, pos + 1
			else parseError(text, pos, "expected ',' or ']'") end
		end

	elseif char == '"' then
		return parseString(text, pos)

	elseif text:sub(pos, pos + 3) == 'true' then
		return true, pos + 4
	elseif text:sub(pos, pos + 4) == 'false' then
		return false, pos + 5
	elseif text:sub(pos, pos + 3) == 'null' then
		return FsJson.null, pos + 4
	end

	local literal = text:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos)
	local number = literal and tonumber(literal)
	if not number then parseError(text, pos, 'unexpected input') end
	return number, pos + #literal
end

--- Parses `text`. Returns (value) on success, or (nil, message) on failure —
--- callers get a message to show rather than an error to catch.
function FsJson.decode(text)
	if type(text) ~= 'string' or text:match('^%s*$') then
		return nil, 'JSON: no input'
	end
	local ok, value = pcall(function()
		local result, pos = parseValue(text, 1)
		pos = skipWhitespace(text, pos)
		if pos <= #text then parseError(text, pos, 'trailing input') end
		return result
	end)
	if not ok then return nil, tostring(value) end
	return value
end

return FsJson
