-- Writing tags into a file. The file is read whole, the format's writer makes the new file with the
-- tags changed and everything else kept, and that goes to a file beside it that then takes the
-- original's place, so a failed write never leaves a half written file behind.

--- Tags to change. A field left out stays as the file has it, `false` removes it, a value sets it.
---@class treble.TagChanges
---@field title string|false|nil
---@field artist string|false|nil
---@field album string|false|nil
---@field albumArtist string|false|nil
---@field track number|false|nil
---@field trackCount number|false|nil
---@field disc number|false|nil
---@field date string|false|nil
---@field genre string|false|nil
---@field comment string|false|nil

local write = {}

local KINDS = {
	title = "string",
	artist = "string",
	album = "string",
	albumArtist = "string",
	track = "number",
	trackCount = "number",
	disc = "number",
	date = "string",
	genre = "string",
	comment = "string"
}

---@param data string
---@return string? writer # The module that writes this format
local function writerFor(data)
	local head = string.sub(data, 1, 12)
	if string.sub(head, 1, 4) == "OggS" then return "treble.write.ogg" end
	if string.sub(head, 1, 4) == "fLaC" then return "treble.write.flac" end
	if string.sub(head, 5, 8) == "ftyp" then return "treble.write.mp4" end
	if string.sub(head, 1, 4) == "RIFF" then return nil end
	if string.sub(head, 1, 3) == "ID3" and #data >= 10 then
		-- FLAC sometimes comes with an ID3v2 tag in front.
		local a, b, c, d = string.byte(data, 7, 10)
		local after = 11 + a * 2097152 + b * 16384 + c * 128 + d + (string.byte(data, 6) % 32 >= 16 and 10 or 0)
		if string.sub(data, after, after + 3) == "fLaC" then return "treble.write.flac" end
		return "treble.write.id3"
	end
	local first, second = string.byte(head, 1, 2)
	if first == 0xFF and second ~= nil and second >= 0xE0 then return "treble.write.id3" end
	return nil
end

--- Changes the tags of a file in place.
---@param path string
---@param changes treble.TagChanges
---@return boolean? ok
---@return string? err
function write.tags(path, changes)
	for field, value in pairs(changes) do
		local kind = KINDS[field]
		if kind == nil then return nil, "unknown tag " .. tostring(field) end
		if value ~= false and type(value) ~= kind then return nil, field .. " must be a " .. kind .. " or false" end
	end

	local file, openErr = io.open(path, "rb")
	if file == nil then return nil, openErr end
	local data = file:read("*a")
	file:close()

	local module = writerFor(data)
	if module == nil then return nil, "can't write tags into this kind of file" end
	local written, err = require(module)(data, changes)
	if written == nil then return nil, err end

	local temporary = path .. ".treble-write"
	local out
	out, err = io.open(temporary, "wb")
	if out == nil then return nil, err end
	local ok
	ok, err = out:write(written)
	out:close()
	if not ok then
		os.remove(temporary)
		return nil, err
	end
	-- Windows will not rename over a file that exists.
	if jit.os == "Windows" then os.remove(path) end
	ok, err = os.rename(temporary, path)
	if not ok then
		os.remove(temporary)
		return nil, err
	end
	return true
end

return write
