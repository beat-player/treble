-- Tags, read out of whatever each format stores them in.
--
-- Only the text and the raw picture bytes are normalised here: decoding an image
-- belongs to an image library, so a picture comes back as its MIME type and its
-- bytes.
local bit = require("bit")

---@class treble.Tags
---@field title string?
---@field artist string?
---@field album string?
---@field albumArtist string?
---@field track number?
---@field trackCount number?
---@field disc number?
---@field date string?
---@field genre string?
---@field comment string?
---@field picture treble.Tags.Picture?
---@field vendor string? # The encoder that wrote the tags

---@class treble.Tags.Picture
---@field mime string
---@field data string # The encoded image itself
---@field description string?

local Tags = {}

local LATIN1 = 0
local UTF16 = 1
local UTF16_BE = 2

---@param value number
---@return string
local function utf8Char(value)
	if value < 0x80 then
		return string.char(value)
	elseif value < 0x800 then
		return string.char(0xC0 | bit.rshift(value, 6), 0x80 | bit.band(value, 0x3F))
	elseif value < 0x10000 then
		return string.char(
			0xE0 | bit.rshift(value, 12),
			0x80 | bit.band(bit.rshift(value, 6), 0x3F),
			0x80 | bit.band(value, 0x3F)
		)
	end

	return string.char(
		0xF0 | bit.rshift(value, 18),
		0x80 | bit.band(bit.rshift(value, 12), 0x3F),
		0x80 | bit.band(bit.rshift(value, 6), 0x3F),
		0x80 | bit.band(value, 0x3F)
	)
end

--- Turns one of the four ID3 text encodings into UTF-8.
---@param raw string
---@param encoding number
---@return string
local function decodeText(raw, encoding)
	if encoding == UTF16 or encoding == UTF16_BE then
		local isBigEndian = encoding == UTF16_BE
		local start = 1

		if encoding == UTF16 and #raw >= 2 then
			-- A byte order mark decides which way round the pairs are.
			local mark = string.byte(raw, 1, 2)
			isBigEndian = mark == nil or string.char(mark) == "\254\255"
			start = 3
		end

		local parts = {}
		local index = start
		while index + 1 <= #raw do
			local first, second = string.byte(raw, index, index + 1)
			local value = isBigEndian and (first * 256 + second) or (second * 256 + first)

			if value >= 0xD800 and value <= 0xDBFF and index + 3 <= #raw then
				-- A surrogate pair carries one character between two units.
				local third, fourth = string.byte(raw, index + 2, index + 3)
				local low = isBigEndian and (third * 256 + fourth) or (fourth * 256 + third)

				value = 0x10000 + (value - 0xD800) * 0x400 + (low - 0xDC00)
				index = index + 4
			else
				index = index + 2
			end

			parts[#parts + 1] = utf8Char(value)
		end

		return table.concat(parts)
	end

	-- Latin-1 and UTF-8 both pass through, the first with its high bytes kept.
	return raw
end

---@param value string
---@return string
local function trim(value)
	return (value:gsub("%z.*$", ""):gsub("%s+$", ""))
end

---@param raw string
---@param encoding number
---@return string text
---@return string rest
local function takeText(raw, encoding)
	local unit = (encoding == UTF16 or encoding == UTF16_BE) and 2 or 1
	local index = 1

	while index + unit - 1 <= #raw do
		if unit == 1 then
			if string.byte(raw, index) == 0 then
				return decodeText(string.sub(raw, 1, index - 1), encoding), string.sub(raw, index + 1)
			end
		elseif string.byte(raw, index) == 0 and string.byte(raw, index + 1) == 0 then
			return decodeText(string.sub(raw, 1, index - 1), encoding), string.sub(raw, index + 2)
		end

		index = index + unit
	end

	return decodeText(raw, encoding), ""
end

---@param value string?
---@return number?
---@return number?
local function parseNumber(value)
	if value == nil then
		return nil
	end

	local current, total = value:match("^(%d+)%s*/%s*(%d+)")

	if current ~= nil then
		return tonumber(current), tonumber(total)
	end

	return tonumber(value:match("^(%d+)")), nil
end

---@param tags treble.Tags
---@param frame string
---@param raw string
local function applyFrame(tags, frame, raw)
	local encoding = string.byte(raw, 1) or LATIN1
	local text = decodeText(string.sub(raw, 2), encoding)

	if frame == "TIT2" or frame == "TT2" then
		tags.title = trim(text)
	elseif frame == "TPE1" or frame == "TP1" then
		tags.artist = trim(text)
	elseif frame == "TALB" or frame == "TAL" then
		tags.album = trim(text)
	elseif frame == "TPE2" or frame == "TP2" then
		tags.albumArtist = trim(text)
	elseif frame == "TRCK" or frame == "TRK" then
		tags.track, tags.trackCount = parseNumber(trim(text))
	elseif frame == "TPOS" or frame == "TPA" then
		tags.disc = parseNumber(trim(text))
	elseif frame == "TDRC" or frame == "TYER" or frame == "TYE" then
		tags.date = trim(text)
	elseif frame == "TCON" or frame == "TCO" then
		tags.genre = trim(text:gsub("^%(%d+%)", ""))
	elseif frame == "COMM" or frame == "COM" then
		-- A comment frame carries a language and a short description first.
		local body = string.sub(string.sub(raw, 2), 4)
		local short, description = takeText(body, encoding)

		tags.comment = trim(short ~= "" and short or decodeText(description, encoding))
	end
end

---@param raw string
---@return string
local function latin1(raw)
	return (raw:gsub("[\128-\255]", function(byte)
		local value = string.byte(byte)

		return utf8Char(value)
	end))
end

---@param raw string
---@return string? mime
---@return string? description
---@return string? data
local function parseAttachedPicture(raw)
	local encoding = string.byte(raw, 1) or LATIN1
	local mime, afterMime = takeText(string.sub(raw, 2), LATIN1)

	-- Then the picture type byte, then a description in the tag's encoding.
	local afterType = string.sub(afterMime, 2)
	local description, data = takeText(afterType, encoding)

	return latin1(mime), description, data
end

--- Reads an ID3v2 tag: the header, its frames, and an attached picture.
---@param raw string
---@return treble.Tags
function Tags.fromId3v2(raw)
	---@type treble.Tags
	local tags = {}

	local major = string.byte(raw, 4) or 3
	local flags = string.byte(raw, 6) or 0
	local _, b2, b3, b4 = string.byte(raw, 7, 10)
	local size = ((string.byte(raw, 7) or 0) * 2097152) + ((b2 or 0) * 16384) + ((b3 or 0) * 128) + (b4 or 0)

	local index = 11

	if bit.band(flags, 0x40) ~= 0 then
		-- An extended header sits before the frames.
		local extSize = (string.byte(raw, index) or 0) * 2097152
			+ (string.byte(raw, index + 1) or 0) * 16384
			+ (string.byte(raw, index + 2) or 0) * 128
			+ (string.byte(raw, index + 3) or 0)
		index = index + 4 + extSize
	end

	local limit = math.min(#raw, 10 + size)

	while index + 6 <= limit do
		local id
		local frameSize
		local header

		if major == 2 then
			id = string.sub(raw, index, index + 2)
			frameSize = (string.byte(raw, index + 3) or 0) * 65536
				+ (string.byte(raw, index + 4) or 0) * 256
				+ (string.byte(raw, index + 5) or 0)
			header = 6
		else
			id = string.sub(raw, index, index + 3)
			if major == 4 then
				frameSize = (string.byte(raw, index + 4) or 0) * 2097152
					+ (string.byte(raw, index + 5) or 0) * 16384
					+ (string.byte(raw, index + 6) or 0) * 128
					+ (string.byte(raw, index + 7) or 0)
			else
				frameSize = (string.byte(raw, index + 4) or 0) * 16777216
					+ (string.byte(raw, index + 5) or 0) * 65536
					+ (string.byte(raw, index + 6) or 0) * 256
					+ (string.byte(raw, index + 7) or 0)
			end
			header = 10
		end

		if frameSize <= 0 or string.byte(id, 1) == 0 then
			break
		end

		local body = string.sub(raw, index + header, index + header + frameSize - 1)

		if id == "APIC" or id == "PIC" then
			local mime, description, data = parseAttachedPicture(body)
			if data ~= nil then
				tags.picture = { mime = mime or "image/", data = data, description = description }
			end
		else
			applyFrame(tags, id, body)
		end

		index = index + header + frameSize
	end

	return tags
end

--- Reads the 128 byte ID3v1 footer.
---@param raw string
---@return treble.Tags?
function Tags.fromId3v1(raw)
	if #raw < 128 or string.sub(raw, 1, 3) ~= "TAG" then
		return nil
	end

	local track = string.byte(raw, 127)

	---@type treble.Tags
	local tags = {
		title = trim(latin1(string.sub(raw, 4, 33))),
		artist = trim(latin1(string.sub(raw, 34, 63))),
		album = trim(latin1(string.sub(raw, 64, 93))),
		date = trim(string.sub(raw, 94, 97)),
	}

	if track ~= nil and track ~= 0 then
		tags.track = track
	end

	local comment = string.sub(raw, 98, 127)
	if string.byte(comment, 29) == 0 and track ~= nil and track ~= 0 then
		comment = string.sub(comment, 1, 28)
	end

	tags.comment = trim(latin1(comment))

	return tags
end

---@param value string
---@return number
local function base64Value(value)
	local byte = string.byte(value)

	if byte == nil then
		return 0
	end

	if byte >= 65 and byte <= 90 then
		return byte - 65
	elseif byte >= 97 and byte <= 122 then
		return byte - 71
	elseif byte >= 48 and byte <= 57 then
		return byte + 4
	elseif byte == 43 then
		return 62
	elseif byte == 47 then
		return 63
	end

	return 0
end

---@param value string
---@return string
local function fromBase64(value)
	local parts = {}
	local accumulator = 0
	local bits = 0

	for index = 1, #value do
		local byte = string.byte(value, index)
		if byte == 61 then
			break
		end

		if byte ~= 10 and byte ~= 13 then
			accumulator = bit.bor(bit.lshift(accumulator, 6), base64Value(string.char(byte)))
			bits = bits + 6

			if bits >= 8 then
				bits = bits - 8
				parts[#parts + 1] = string.char(bit.band(bit.rshift(accumulator, bits), 0xFF))
			end
		end
	end

	return table.concat(parts)
end

---@param mime string
---@param description string?
---@param data string
---@return treble.Tags.Picture
function Tags.fromPicture(mime, description, data)
	return { mime = mime, description = description, data = data }
end

--- Reads a FLAC picture block, which is also how a Vorbis comment carries art.
---@param raw string
---@return treble.Tags.Picture?
function Tags.fromPictureBlock(raw)
	if #raw < 32 then
		return nil
	end

	local function readUint32(offset)
		return (string.byte(raw, offset) or 0) * 16777216
			+ (string.byte(raw, offset + 1) or 0) * 65536
			+ (string.byte(raw, offset + 2) or 0) * 256
			+ (string.byte(raw, offset + 3) or 0)
	end

	local mimeLength = readUint32(5)
	local mime = string.sub(raw, 9, 8 + mimeLength)
	local descriptionStart = 9 + mimeLength
	local descriptionLength = readUint32(descriptionStart)
	local dataStart = descriptionStart + 4 + descriptionLength + 20
	local dataLength = readUint32(dataStart - 4)

	return Tags.fromPicture(
		mime,
		string.sub(raw, descriptionStart + 4, descriptionStart + 3 + descriptionLength),
		string.sub(raw, dataStart, dataStart + dataLength - 1)
	)
end

--- Reads the comment block a FLAC metadata block holds: a length prefixed list,
--- as dr_flac passes it over.
---@param packed string
---@param count number
---@param vendor string?
---@return treble.Tags
function Tags.fromFlacComments(packed, count, vendor)
	---@type string[]
	local comments = {}
	local index = 1

	for _ = 1, count do
		if index + 3 > #packed then
			break
		end

		local a, b, c, d = string.byte(packed, index, index + 3)
		local length = (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216

		comments[#comments + 1] = string.sub(packed, index + 4, index + 3 + length)
		index = index + 4 + length
	end

	return Tags.fromVorbisComments(comments, vendor)
end

--- Reads the "KEY=value" list an Ogg or FLAC stream carries.
---@param comments string[]
---@param vendor string?
---@return treble.Tags
function Tags.fromVorbisComments(comments, vendor)
	---@type treble.Tags
	local tags = { vendor = vendor }

	for _, comment in ipairs(comments) do
		local key, value = comment:match("^([^=]+)=(.*)$")

		if key ~= nil then
			key = key:upper()

			if key == "TITLE" then
				tags.title = value
			elseif key == "ARTIST" then
				tags.artist = tags.artist == nil and value or tags.artist .. ", " .. value
			elseif key == "ALBUM" then
				tags.album = value
			elseif key == "ALBUMARTIST" or key == "ALBUM ARTIST" then
				tags.albumArtist = value
			elseif key == "TRACKNUMBER" then
				tags.track, tags.trackCount = parseNumber(value)
			elseif key == "TRACKTOTAL" or key == "TOTALTRACKS" then
				tags.trackCount = tonumber(value) or tags.trackCount
			elseif key == "DISCNUMBER" then
				tags.disc = parseNumber(value)
			elseif key == "DATE" or key == "YEAR" then
				tags.date = value
			elseif key == "GENRE" then
				tags.genre = value
			elseif key == "COMMENT" or key == "DESCRIPTION" then
				tags.comment = value
			elseif key == "METADATA_BLOCK_PICTURE" and tags.picture == nil then
				tags.picture = Tags.fromPictureBlock(fromBase64(value))
			end
		end
	end

	return tags
end

return Tags
