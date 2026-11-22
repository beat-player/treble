-- The MP4 container as an AAC file uses it.
--
-- An M4A is boxes all the way down: the movie header names the tracks, a sound
-- track's sample table says where each access unit sits in the file, and an
-- optional list holds the iTunes tags. Reading it is length arithmetic and
-- seeks, so this module never decodes anything; `aac.lua` feeds the access
-- units it locates to FDK, and `inspect.lua` uses the same parse to answer a
-- library scan.
local bit = require("bit")
local ffi = require("ffi")
local utf8 = require("utf8")
local Tags = require("treble.tags")

local Mp4 = {}

local TWO32 = 4294967296
local TWO63 = 9223372036854775808
local TWO64 = 18446744073709551616

-- ────────────────────────────────────────────────────────────────
-- byte reading
-- ────────────────────────────────────────────────────────────────

---@param data string
---@param at number 1 based offset
---@return number
local function be16(data, at)
	return (data:byte(at) or 0) * 256 + (data:byte(at + 1) or 0)
end

---@param data string
---@param at number 1 based offset
---@return number
local function be32(data, at)
	return (data:byte(at) or 0) * 16777216 + (data:byte(at + 1) or 0) * 65536
		+ (data:byte(at + 2) or 0) * 256 + (data:byte(at + 3) or 0)
end

---@param data string
---@param at number 1 based offset
---@return number
local function be64(data, at)
	return be32(data, at) * TWO32 + be32(data, at + 4)
end

---@param value number
---@return number
local function signed32(value)
	return value >= 2147483648 and value - TWO32 or value
end

---@param value number
---@return number
local function signed64(value)
	return value >= TWO63 and value - TWO64 or value
end

-- ────────────────────────────────────────────────────────────────
-- sources to read from
-- ────────────────────────────────────────────────────────────────

---@class treble.formats.mp4.Reader
---@field size number
---@field read fun(self: treble.formats.mp4.Reader, offset: number, count: number): string?
---@field close fun(self: treble.formats.mp4.Reader)

---@class treble.formats.mp4.FileReader: treble.formats.mp4.Reader
---@field file file?
---@field size number
---@field owns boolean?
local FileReader = {}
FileReader.__index = FileReader

---@param file file*
---@param size number
---@param owns boolean # Whether closing the reader also closes the file
---@return treble.formats.mp4.Reader
function Mp4.fileReader(file, size, owns)
	return setmetatable({ file = file, size = size, owns = owns }, FileReader)
end

---@param offset number
---@param count number
---@return string?
function FileReader:read(offset, count)
	if count <= 0 then return "" end
	if offset < 0 or offset >= self.size then return nil end

	local file = self.file
	if file == nil then return nil end

	local want = math.min(count, self.size - offset)
	if file:seek("set", offset) == nil then return nil end

	return file:read(want)
end

function FileReader:close()
	if self.owns and self.file ~= nil then
		self.file:close()
	end
	self.file = nil
end

---@class treble.formats.mp4.MemoryReader: treble.formats.mp4.Reader
---@field pointer ffi.cdata*?
---@field size number
local MemoryReader = {}
MemoryReader.__index = MemoryReader

---@param pointer ffi.cdata*
---@param size number
---@return treble.formats.mp4.Reader
function Mp4.memoryReader(pointer, size)
	return setmetatable({ pointer = ffi.cast("const char*", pointer), size = size }, MemoryReader)
end

---@param offset number
---@param count number
---@return string?
function MemoryReader:read(offset, count)
	if count <= 0 then return "" end
	if offset < 0 or offset >= self.size then return nil end

	local pointer = self.pointer
	if pointer == nil then return nil end

	local want = math.min(count, self.size - offset)
	return ffi.string(pointer + offset, want)
end

function MemoryReader:close()
	-- The caller owns the memory and must keep it alive until the source closes.
	self.pointer = nil
end

--- Opens a file and hands back a reader that owns its handle.
---@param path string
---@return treble.formats.mp4.Reader? reader
---@return string? err
function Mp4.openPath(path)
	local file, err = io.open(path, "rb")
	if file == nil then
		return nil, "Failed to open audio file: " .. tostring(err)
	end

	local size = file:seek("end")
	if size == nil then
		file:close()
		return nil, "Failed to measure audio file"
	end

	return Mp4.fileReader(file, size, true)
end

-- ────────────────────────────────────────────────────────────────
-- boxes
-- ────────────────────────────────────────────────────────────────

---@class treble.formats.mp4.Box
---@field kind string
---@field at number
---@field body number
---@field stop number

---@param reader treble.formats.mp4.Reader
---@param at number
---@param limit number
---@return treble.formats.mp4.Box?
local function boxAt(reader, at, limit)
	local header = reader:read(at, 8)
	if header == nil or #header < 8 then return nil end

	local size = be32(header, 1)
	local kind = header:sub(5, 8)
	local headerSize = 8

	if size == 1 then
		-- A 64 bit size follows the type, for a box bigger than four gigabytes.
		local large = reader:read(at + 8, 8)
		if large == nil or #large < 8 then return nil end
		size = be64(large, 1)
		headerSize = 16
	elseif size == 0 then
		-- A box sized zero runs to the end of its parent.
		size = limit - at
	end

	if size < headerSize or at + size > limit then return nil end

	return { kind = kind, at = at, body = at + headerSize, stop = at + size }
end

--- Walks the boxes between two offsets. A malformed box ends the walk.
---@param reader treble.formats.mp4.Reader
---@param start number
---@param stop number
---@return fun(): treble.formats.mp4.Box?
local function children(reader, start, stop)
	local at = start

	return function()
		if at == nil or at >= stop then return nil end

		local box = boxAt(reader, at, stop)
		if box == nil then
			at = nil
			return nil
		end

		at = box.stop
		return box
	end
end

---@param reader treble.formats.mp4.Reader
---@param start number
---@param stop number
---@param kind string
---@return treble.formats.mp4.Box?
local function findChild(reader, start, stop, kind)
	for box in children(reader, start, stop) do
		if box.kind == kind then return box end
	end

	return nil
end

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return string?
local function bodyOf(reader, box)
	return reader:read(box.body, box.stop - box.body)
end

-- ────────────────────────────────────────────────────────────────
-- track headers
-- ────────────────────────────────────────────────────────────────

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return number? timescale
---@return number? duration
local function parseMdhd(reader, box)
	local data = bodyOf(reader, box)
	if data == nil then return nil end

	local version = data:byte(1) or 0

	if version == 1 then
		if #data < 32 then return nil end
		return be32(data, 21), be64(data, 25)
	end

	if #data < 20 then return nil end
	return be32(data, 13), be32(data, 17)
end

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return string?
local function parseHandler(reader, box)
	local data = reader:read(box.body, 12)
	if data == nil or #data < 12 then return nil end

	return data:sub(9, 12)
end

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return number?
local function parseMvhd(reader, box)
	local data = bodyOf(reader, box)
	if data == nil then return nil end

	local version = data:byte(1) or 0
	if version == 1 then
		if #data < 24 then return nil end
		return be32(data, 21)
	end

	if #data < 16 then return nil end
	return be32(data, 13)
end

---@class treble.formats.mp4.Stts
---@field count number
---@field delta number

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return treble.formats.mp4.Stts[]?
local function parseStts(reader, box)
	local data = bodyOf(reader, box)
	if data == nil or #data < 8 then return nil end

	local count = be32(data, 5)
	local entries = {}
	local at = 9

	for _ = 1, count do
		if at + 7 > #data then break end
		entries[#entries + 1] = { count = be32(data, at), delta = be32(data, at + 4) }
		at = at + 8
	end

	return entries
end

---@class treble.formats.mp4.Stsc
---@field firstChunk number
---@field samplesPerChunk number

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return treble.formats.mp4.Stsc[]?
local function parseStsc(reader, box)
	local data = bodyOf(reader, box)
	if data == nil or #data < 8 then return nil end

	local count = be32(data, 5)
	local entries = {}
	local at = 9

	for _ = 1, count do
		if at + 11 > #data then break end
		entries[#entries + 1] = {
			firstChunk = be32(data, at),
			samplesPerChunk = be32(data, at + 4),
		}
		at = at + 12
	end

	return entries
end

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return number? constantSize
---@return number? sampleCount
---@return number[]? sizes
local function parseStsz(reader, box)
	local data = bodyOf(reader, box)
	if data == nil or #data < 12 then return nil end

	local constantSize = be32(data, 5)
	local sampleCount = be32(data, 9)

	---@type number[]
	local sizes = {}
	if constantSize == 0 then
		local at = 13
		for _ = 1, sampleCount do
			if at + 3 > #data then break end
			sizes[#sizes + 1] = be32(data, at)
			at = at + 4
		end
	end

	return constantSize, sampleCount, sizes
end

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@param large boolean # co64 stores eight byte offsets
---@return number[]?
local function parseChunkOffsets(reader, box, large)
	local data = bodyOf(reader, box)
	if data == nil or #data < 8 then return nil end

	local count = be32(data, 5)
	local step = large and 8 or 4
	local offsets = {}
	local at = 9

	for _ = 1, count do
		if at + step - 1 > #data then break end
		offsets[#offsets + 1] = large and be64(data, at) or be32(data, at)
		at = at + step
	end

	return offsets
end

---@class treble.formats.mp4.Edit
---@field segmentDuration number # In the movie timescale
---@field mediaTime number # In the media timescale, where playback begins

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return treble.formats.mp4.Edit?
local function parseElst(reader, box)
	local data = bodyOf(reader, box)
	if data == nil or #data < 8 then return nil end

	local version = data:byte(1) or 0
	local count = be32(data, 5)
	local at = 9

	for _ = 1, count do
		local entry

		if version == 1 then
			if at + 19 > #data then break end
			entry = {
				segmentDuration = be64(data, at),
				mediaTime = signed64(be64(data, at + 8)),
			}
			at = at + 20
		else
			if at + 11 > #data then break end
			entry = {
				segmentDuration = be32(data, at),
				mediaTime = signed32(be32(data, at + 4)),
			}
			at = at + 12
		end

		-- An empty edit (media time -1) only delays the track. The first real
		-- edit is where the audible samples begin.
		if entry.mediaTime >= 0 then return entry end
	end

	return nil
end

-- ────────────────────────────────────────────────────────────────
-- sample entries and the AudioSpecificConfig
-- ────────────────────────────────────────────────────────────────

---@param data string
---@return fun(n: number): number?
local function bitReader(data)
	local position = 0

	return function(n)
		local value = 0

		for _ = 1, n do
			local byte = data:byte(math.floor(position / 8) + 1)
			if byte == nil then return nil end

			local shift = 7 - (position % 8)
			value = value * 2 + bit.band(bit.rshift(byte, shift), 1)
			position = position + 1
		end

		return value
	end
end

-- Sampling frequencies by AudioSpecificConfig index.
local SAMPLE_RATES = {
	96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
	16000, 12000, 11025, 8000, 7350,
}

-- Channel configurations 1 to 7, in order.
local CHANNEL_COUNTS = { 1, 2, 3, 4, 5, 6, 8 }

---@class treble.formats.mp4.AudioConfig
---@field sampleRate number
---@field channels number

--- Reads the fields of an MPEG-4 AudioSpecificConfig. The decoder confirms them
--- from its own stream info once it has seen a frame.
---@param asc string
---@return treble.formats.mp4.AudioConfig?
local function parseAsc(asc)
	local read = bitReader(asc)

	local aot = read(5)
	if aot == nil then return nil end
	if aot == 31 then
		local extended = read(6)
		if extended == nil then return nil end
		aot = 32 + extended
	end

	local index = read(4)
	if index == nil then return nil end

	local sampleRate
	if index == 15 then
		sampleRate = read(24)
	else
		sampleRate = SAMPLE_RATES[index + 1]
	end
	if sampleRate == nil then return nil end
	---@cast sampleRate number

	local channelConfig = read(4)
	if channelConfig == nil then return nil end

	if aot == 5 or aot == 29 then
		-- HE-AAC puts the core rate first and the extension rate after the
		-- channel configuration; the extension is what the decoder outputs.
		local extension = read(4)
		if extension == nil then return nil end

		local extensionRate
		if extension == 15 then
			extensionRate = read(24)
		else
			extensionRate = SAMPLE_RATES[extension + 1]
		end
		if extensionRate ~= nil then sampleRate = extensionRate end
	end

	return {
		sampleRate = sampleRate,
		channels = CHANNEL_COUNTS[channelConfig] or 0,
	}
end

---@param data string
---@param at number 1 based start of the descriptor
---@return number? tag
---@return number? start # first byte of the descriptor body
---@return number? stop # last byte of the descriptor body
local function descriptor(data, at)
	local tag = data:byte(at)
	if tag == nil then return nil end

	local size = 0
	local cursor = at + 1

	for _ = 1, 4 do
		local byte = data:byte(cursor)
		if byte == nil then return nil end
		cursor = cursor + 1
		size = size * 128 + bit.band(byte, 0x7F)

		if byte < 128 then break end
	end

	return tag, cursor, math.min(cursor + size - 1, #data)
end

--- Reads the DecoderSpecificInfo out of an esds box: the AudioSpecificConfig
--- bytes the decoder needs before it sees a frame.
---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return string?
local function parseEsds(reader, box)
	local data = bodyOf(reader, box)
	if data == nil or #data < 5 then return nil end

	-- The FullBox header is four bytes; the ES_Descriptor follows.
	local tag, start, stop = descriptor(data, 5)
	if tag ~= 0x03 or start == nil or stop == nil then return nil end

	local flags = data:byte(start + 2) or 0
	local cursor = start + 3

	if bit.band(flags, 0x80) ~= 0 then cursor = cursor + 2 end
	if bit.band(flags, 0x40) ~= 0 then
		local length = data:byte(cursor) or 0
		cursor = cursor + 1 + length
	end
	if bit.band(flags, 0x20) ~= 0 then cursor = cursor + 2 end

	while cursor < stop do
		local nested, nestedStart, nestedStop = descriptor(data, cursor)
		if nested == nil or nestedStart == nil or nestedStop == nil then break end

		if nested == 0x04 then
			-- objectTypeIndication, streamType, bufferSizeDB, maxBitrate and
			-- avgBitrate come before the DecoderSpecificInfo descriptor.
			local configAt = nestedStart + 13

			while configAt < nestedStop do
				local config, configStart, configStop = descriptor(data, configAt)
				if config == nil or configStart == nil or configStop == nil then break end

				if config == 0x05 then
					return data:sub(configStart, configStop)
				end

				configAt = configStop + 1
			end
		end

		cursor = nestedStop + 1
	end

	return nil
end

---@class treble.formats.mp4.SampleEntry
---@field codec string
---@field channels number
---@field sampleRate number
---@field asc string?

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return treble.formats.mp4.SampleEntry?
local function parseStsd(reader, box)
	local data = reader:read(box.body, 8)
	if data == nil or #data < 8 then return nil end

	local count = be32(data, 5)
	local at = box.body + 8

	for _ = 1, math.min(count, 8) do
		local entry = boxAt(reader, at, box.stop)
		if entry == nil then break end

		if entry.kind == "mp4a" or entry.kind == "alac" or entry.kind == "ac-3"
			or entry.kind == "ec-3" then
			local fields = reader:read(entry.body, 28)
			if fields == nil or #fields < 28 then return nil end

			local version = be16(fields, 9)
			local codec = entry.kind
			local channels = be16(fields, 17)
			local sampleRate = bit.rshift(be32(fields, 25), 16)

			-- A QuickTime version 1 sound description carries sixteen more bytes
			-- before its child boxes.
			local childAt = entry.body + 28 + (version == 1 and 16 or 0)
			local esds = findChild(reader, childAt, entry.stop, "esds")

			return {
				codec = codec,
				channels = channels,
				sampleRate = sampleRate,
				asc = esds ~= nil and parseEsds(reader, esds) or nil,
			}
		end

		at = entry.stop
	end

	return nil
end

-- ────────────────────────────────────────────────────────────────
-- iTunes tags
-- ────────────────────────────────────────────────────────────────

---@class treble.formats.mp4.Data
---@field kind number # data type: 1 UTF-8, 2 UTF-16, 13 JPEG, 14 PNG
---@field value string

---@param reader treble.formats.mp4.Reader
---@param box treble.formats.mp4.Box
---@return treble.formats.mp4.Data?
local function parseData(reader, box)
	local header = reader:read(box.body, 8)
	if header == nil or #header < 8 then return nil end

	local length = box.stop - box.body - 8
	if length < 0 then return nil end

	local value = length > 0 and reader:read(box.body + 8, length) or ""
	if value == nil then return nil end

	return { kind = bit.band(be32(header, 1), 0xFFFFFF), value = value }
end

---@param data treble.formats.mp4.Data
---@return string
local function textOf(data)
	local value = data.value

	if data.kind == 2 then
		value = utf8.fromUTF16(value, true)
	end

	return (value:gsub("%z+$", ""))
end

---@param value string
---@return string
local function trimmed(value)
	return (value:gsub("%z+$", ""))
end

local TEXT_ITEMS = {
	["\169nam"] = "title",
	["\169ART"] = "artist",
	["\169alb"] = "album",
	["aART"] = "albumArtist",
	["\169day"] = "date",
	["\169gen"] = "genre",
	["\169cmt"] = "comment",
	["\169too"] = "vendor",
}

---@class treble.formats.mp4.TagFields: treble.Tags.ItunesFields
---@field title string?
---@field artist string?
---@field album string?
---@field albumArtist string?
---@field date string?
---@field genre string?
---@field genreIndex number?
---@field comment string?
---@field vendor string?
---@field track number?
---@field trackCount number?
---@field disc number?
---@field picture treble.Tags.Picture?
---@field freeform { name: string, value: string }[]

---@param reader treble.formats.mp4.Reader
---@param item treble.formats.mp4.Box
---@param fields treble.formats.mp4.TagFields
---@param hasPicture boolean
---@param readPictures boolean
---@return boolean hasPicture
local function parseTagItem(reader, item, fields, hasPicture, readPictures)
	local textField = TEXT_ITEMS[item.kind]

	if item.kind == "covr" then
		if not readPictures then return true end

		for child in children(reader, item.body, item.stop) do
			if child.kind == "data" then
				local data = parseData(reader, child)
				if data ~= nil then
					local mime = data.kind == 13 and "image/jpeg"
						or data.kind == 14 and "image/png"
						or (data.value:sub(1, 4) == "\137PNG" and "image/png" or "image/jpeg")

					fields.picture = Tags.fromPicture(mime, nil, data.value)
				end
				break
			end
		end

		return true
	end

	if item.kind == "----" then
		local mean = nil
		local name = nil
		local data = nil

		for child in children(reader, item.body, item.stop) do
			if child.kind == "mean" then
				local value = reader:read(child.body + 4, child.stop - child.body - 4)
				if value ~= nil then mean = trimmed(value) end
			elseif child.kind == "name" then
				local value = reader:read(child.body + 4, child.stop - child.body - 4)
				if value ~= nil then name = trimmed(value) end
			elseif child.kind == "data" then
				data = parseData(reader, child)
			end
		end

		-- `mean` is the namespace, usually com.apple.iTunes. tags.lua only has
		-- the field names to match, so the name is what decides a mapping.
		if name ~= nil and data ~= nil and (mean == nil or mean == "com.apple.iTunes") then
			local value = textOf(data)
			fields.freeform[#fields.freeform + 1] = { name = name, value = value }
		end

		return hasPicture
	end

	if textField == nil and item.kind ~= "trkn" and item.kind ~= "disk"
		and item.kind ~= "gnre" then
		return hasPicture
	end

	local data = nil
	for child in children(reader, item.body, item.stop) do
		if child.kind == "data" then
			data = parseData(reader, child)
			break
		end
	end

	if data == nil then return hasPicture end

	if textField ~= nil then
		---@diagnostic disable-next-line: assign-type-mismatch
		fields[textField] = textOf(data)
	elseif item.kind == "trkn" then
		if #data.value >= 6 then
			fields.track = be16(data.value, 3)
			fields.trackCount = be16(data.value, 5)
		end
	elseif item.kind == "disk" then
		if #data.value >= 6 then
			fields.disc = be16(data.value, 3)
		end
	elseif item.kind == "gnre" then
		if #data.value >= 2 then
			fields.genreIndex = be16(data.value, 1)
		end
	end

	return hasPicture
end

---@param reader treble.formats.mp4.Reader
---@param ilst treble.formats.mp4.Box
---@param fields treble.formats.mp4.TagFields
---@param readPictures boolean
---@return boolean hasPicture
local function parseIlst(reader, ilst, fields, readPictures)
	local hasPicture = false

	for item in children(reader, ilst.body, ilst.stop) do
		hasPicture = parseTagItem(reader, item, fields, hasPicture, readPictures)
	end

	return hasPicture
end

---@param reader treble.formats.mp4.Reader
---@param meta treble.formats.mp4.Box
---@param fields treble.formats.mp4.TagFields
---@param readPictures boolean
---@return boolean hasPicture
local function parseMeta(reader, meta, fields, readPictures)
	-- A meta box is a FullBox: four bytes of version and flags sit before its
	-- children.
	local ilst = findChild(reader, meta.body + 4, meta.stop, "ilst")
	if ilst == nil then return false end

	return parseIlst(reader, ilst, fields, readPictures)
end

-- ────────────────────────────────────────────────────────────────
-- track parsing
-- ────────────────────────────────────────────────────────────────

---@class treble.formats.mp4.Track
---@field codec string
---@field handler string
---@field timescale number
---@field duration number
---@field sampleRate number
---@field channels number
---@field asc string?
---@field stts treble.formats.mp4.Stts[]
---@field stsc treble.formats.mp4.Stsc[]
---@field chunks { offset: number, firstSample: number, samples: number }[]
---@field constantSize number
---@field sizes number[]
---@field sampleCount number
---@field sampleBytes number
---@field edit treble.formats.mp4.Edit?
---@field priming number
---@field frameCount number

---@param reader treble.formats.mp4.Reader
---@param trak treble.formats.mp4.Box
---@return treble.formats.mp4.Track?
local function parseTrak(reader, trak)
	local handler = nil
	local timescale = 0
	local duration = 0
	local edit = nil
	local entry = nil
	local stts, stsc, stszConstant, stszCount, stszSizes, chunkOffsets = nil, nil, 0, 0, nil, nil

	for box in children(reader, trak.body, trak.stop) do
		if box.kind == "edts" then
			local elst = findChild(reader, box.body, box.stop, "elst")
			if elst ~= nil then edit = parseElst(reader, elst) end
		elseif box.kind == "mdia" then
			local stbl = nil

			for child in children(reader, box.body, box.stop) do
				if child.kind == "mdhd" then
					local mediaTimescale, mediaDuration = parseMdhd(reader, child)
					timescale = mediaTimescale or 0
					duration = mediaDuration or 0
				elseif child.kind == "hdlr" then
					handler = parseHandler(reader, child)
				elseif child.kind == "minf" then
					stbl = findChild(reader, child.body, child.stop, "stbl")
				end
			end

			if stbl ~= nil then
				for child in children(reader, stbl.body, stbl.stop) do
					if child.kind == "stsd" then
						entry = parseStsd(reader, child)
					elseif child.kind == "stts" then
						stts = parseStts(reader, child)
					elseif child.kind == "stsc" then
						stsc = parseStsc(reader, child)
					elseif child.kind == "stsz" then
						stszConstant, stszCount, stszSizes = parseStsz(reader, child)
					elseif child.kind == "stco" then
						chunkOffsets = parseChunkOffsets(reader, child, false)
					elseif child.kind == "co64" then
						chunkOffsets = parseChunkOffsets(reader, child, true)
					end
				end
			end
		end
	end

	if handler == nil or entry == nil or stts == nil or stsc == nil or chunkOffsets == nil then
		return nil
	end

	local constantSize = stszConstant or 0
	local sizes = stszSizes or {}
	local sampleCount = stszCount or 0

	-- A constant sample size still needs a count; one file in the wild states
	-- the size and leaves the count to the time table.
	if sampleCount == 0 then
		for _, entryTime in ipairs(stts) do
			sampleCount = sampleCount + entryTime.count
		end
	end

	---@type { offset: number, firstSample: number, samples: number }[]
	local chunks = {}
	local sample = 0
	local mapping = 1

	for index = 1, #chunkOffsets do
		if sample >= sampleCount then break end

		while mapping + 1 <= #stsc and stsc[mapping + 1].firstChunk <= index do
			mapping = mapping + 1
		end

		local perChunk = stsc[mapping] ~= nil and stsc[mapping].samplesPerChunk or 0
		local count = math.min(perChunk, sampleCount - sample)
		if count <= 0 then break end

		chunks[#chunks + 1] = {
			offset = chunkOffsets[index],
			firstSample = sample,
			samples = count,
		}
		sample = sample + count
	end

	local sampleBytes = constantSize > 0 and constantSize * sampleCount or 0
	if constantSize == 0 then
		for _, size in ipairs(sizes) do sampleBytes = sampleBytes + size end
	end

	return {
		codec = entry.codec,
		handler = handler,
		timescale = timescale,
		duration = duration,
		sampleRate = entry.sampleRate,
		channels = entry.channels,
		asc = entry.asc,
		stts = stts,
		stsc = stsc,
		chunks = chunks,
		constantSize = constantSize,
		sizes = sizes,
		sampleCount = sampleCount,
		sampleBytes = sampleBytes,
		edit = edit,
		priming = 0,
		frameCount = 0,
	}
end

-- ────────────────────────────────────────────────────────────────
-- sample tables
-- ────────────────────────────────────────────────────────────────

---@param track treble.formats.mp4.Track
---@param index number 0 based sample number
---@return number size
function Mp4.sampleSize(track, index)
	if track.constantSize > 0 then return track.constantSize end
	return track.sizes[index + 1] or 0
end

---@param track treble.formats.mp4.Track
---@param index number 0 based
---@return number? offset
---@return number? size
function Mp4.sampleOffset(track, index)
	if index < 0 or index >= track.sampleCount then return nil end

	local chunks = track.chunks
	if #chunks == 0 then return nil end

	-- Find the last chunk that starts at or before this sample.
	local low, high = 1, #chunks
	while low < high do
		local middle = math.floor((low + high + 1) / 2)
		if chunks[middle].firstSample <= index then
			low = middle
		else
			high = middle - 1
		end
	end

	local chunk = chunks[low]
	local offset = chunk.offset
	for sample = chunk.firstSample, index - 1 do
		offset = offset + Mp4.sampleSize(track, sample)
	end

	return offset, Mp4.sampleSize(track, index)
end

--- Reads bytes from the concatenated sample payload, which is where the audio
--- lives regardless of how many chunks or boxes the file splits it into.
---@param reader treble.formats.mp4.Reader
---@param track treble.formats.mp4.Track
---@param offset number byte offset in the concatenated payload
---@param count number
---@return string
function Mp4.sampleRange(reader, track, offset, count)
	if count <= 0 then return "" end

	---@type string[]
	local pieces = {}
	local produced = 0
	local wanted = offset
	local remaining = count

	for _, chunk in ipairs(track.chunks) do
		local within = 0

		for sample = chunk.firstSample, chunk.firstSample + chunk.samples - 1 do
			local size = Mp4.sampleSize(track, sample)

			if size > 0 then
				local after = produced + size

				if after > wanted then
					local from = math.max(wanted, produced) - produced
					local take = math.min(size - from, remaining)
					local data = reader:read(chunk.offset + within + from, take)

					if data ~= nil and #data > 0 then
						---@cast data string
						pieces[#pieces + 1] = data
						remaining = remaining - #data
						wanted = wanted + #data
					end

					if remaining <= 0 then return table.concat(pieces) end
				end

				produced = after
			end

			within = within + size
		end
	end

	return table.concat(pieces)
end

--- The media frame at which a sample begins.
---@param track treble.formats.mp4.Track
---@param sample number 0 based
---@return number
function Mp4.sampleStart(track, sample)
	local frame = 0
	local index = 0

	for _, entry in ipairs(track.stts) do
		if entry.delta <= 0 then return frame end
		if sample < index + entry.count then
			return frame + (sample - index) * entry.delta
		end

		frame = frame + entry.count * entry.delta
		index = index + entry.count
	end

	return frame
end

--- The sample that holds a media frame.
---@param track treble.formats.mp4.Track
---@param mediaFrame number
---@return number sample 0 based
function Mp4.sampleAt(track, mediaFrame)
	local frame = 0
	local index = 0

	for _, entry in ipairs(track.stts) do
		if entry.delta <= 0 then return index end

		local span = entry.count * entry.delta
		if mediaFrame < frame + span then
			return index + math.floor((mediaFrame - frame) / entry.delta)
		end

		frame = frame + span
		index = index + entry.count
	end

	return track.sampleCount
end

-- ────────────────────────────────────────────────────────────────
-- gapless playback
-- ────────────────────────────────────────────────────────────────

---@param freeform { name: string, value: string }[]
---@param name string
---@return string?
local function freeformValue(freeform, name)
	for _, item in ipairs(freeform) do
		if item.name == name then return item.value end
	end

	return nil
end

--- Work out where the audible samples begin and end. AAC encoders pad the
--- start with priming and often the end with silence; an edit list or an
--- iTunSMPB tag says how much, and both are common in files from iTunes.
---@param file treble.formats.mp4.File
local function applyGapless(file)
	local track = file.track
	if track == nil then return end

	local priming = 0
	local frames = track.duration

	if track.edit ~= nil then
		priming = math.max(0, track.edit.mediaTime)

		local segment = track.edit.segmentDuration
		if segment > 0 and file.movieTimescale > 0 and track.timescale > 0 then
			local segmentFrames = math.floor(segment * track.timescale / file.movieTimescale + 0.5)
			local remaining = math.max(0, track.duration - priming)

			-- A segment that runs to the end of the media is the file's whole
			-- audible length; its conversion to the media timescale can land a
			-- fraction of a sample away, so prefer the exact remainder.
			if math.abs(segmentFrames - remaining) <= 2 then
				frames = remaining
			elseif segmentFrames > 0 then
				frames = math.min(segmentFrames, remaining)
			end
		else
			frames = math.max(0, track.duration - priming)
		end
	else
		local smpb = freeformValue(file.freeform, "iTunSMPB")
		if smpb ~= nil then
			local _, delay, padding, original = smpb:match("^%s*(%x+)%s+(%x+)%s+(%x+)%s+(%x+)")

			if delay ~= nil then
				priming = tonumber(delay, 16) or 0

				local endPadding = tonumber(padding, 16) or 0
				local total = tonumber(original, 16) or 0

				if total > 0 then
					frames = total
				else
					frames = math.max(0, track.duration - priming - endPadding)
				end
			end
		end
	end

	if frames <= 0 then
		frames = math.max(0, track.duration - priming)
	end

	track.priming = math.max(0, priming)
	track.frameCount = math.max(0, math.min(frames, track.duration - track.priming))
end

-- ────────────────────────────────────────────────────────────────
-- entry point
-- ────────────────────────────────────────────────────────────────

---@class treble.formats.mp4.File
---@field track treble.formats.mp4.Track?
---@field tags treble.Tags?
---@field hasPicture boolean
---@field movieTimescale number
---@field freeform { name: string, value: string }[]
---@field mdat { at: number, stop: number }?

--- Reads the movie header, the AAC track and the iTunes tags.
---@param reader treble.formats.mp4.Reader
---@param opts { pictures: boolean? }? # pictures defaults to true
---@return treble.formats.mp4.File? file
---@return string? err
function Mp4.parse(reader, opts)
	opts = opts or {}

	---@type treble.formats.mp4.File
	local file = {
		movieTimescale = 0,
		hasPicture = false,
		freeform = {},
	}

	local moov = nil

	for box in children(reader, 0, reader.size) do
		if box.kind == "moov" then
			moov = box
		elseif box.kind == "mdat" then
			file.mdat = { at = box.body, stop = box.stop }
		end
	end

	if moov == nil then
		return nil, "Malformed MP4 file: no movie header"
	end

	---@type treble.formats.mp4.Track[]
	local audioTracks = {}

	---@type treble.formats.mp4.TagFields
	local fields = { freeform = {} }

	for box in children(reader, moov.body, moov.stop) do
		if box.kind == "mvhd" then
			file.movieTimescale = parseMvhd(reader, box) or file.movieTimescale
		elseif box.kind == "trak" then
			local track = parseTrak(reader, box)
			if track ~= nil and track.handler == "soun" then
				audioTracks[#audioTracks + 1] = track
			end
		elseif box.kind == "udta" then
			local meta = findChild(reader, box.body, box.stop, "meta")
			if meta ~= nil then
				file.hasPicture = parseMeta(reader, meta, fields, opts.pictures ~= false)
					or file.hasPicture
			end
		elseif box.kind == "meta" then
			file.hasPicture = parseMeta(reader, box, fields, opts.pictures ~= false)
				or file.hasPicture
		end
	end

	-- The first AAC sound track is the one to play. Another codec in an MP4
	-- fails cleanly instead of being fed to the AAC decoder.
	local track = nil
	for _, candidate in ipairs(audioTracks) do
		if candidate.codec == "mp4a" then
			track = candidate
			break
		end
	end

	if track == nil then
		if #audioTracks > 0 then
			return nil, "Unsupported codec in MP4 file: " .. tostring(audioTracks[1].codec)
		end

		return nil, "No audio track in MP4 file"
	end

	if track.asc == nil then
		return nil, "MP4 AAC track has no AudioSpecificConfig"
	end

	local config = parseAsc(track.asc)
	if config ~= nil then
		if config.sampleRate > 0 then track.sampleRate = config.sampleRate end
		if config.channels > 0 then track.channels = config.channels end
	end

	if track.timescale <= 0 or track.sampleRate <= 0 or track.channels <= 0 then
		return nil, "MP4 AAC track has no usable sample rate or channel count"
	end

	-- The time table's total can be the only duration when the header leaves it out.
	if track.duration <= 0 then
		track.duration = Mp4.sampleStart(track, track.sampleCount)
	end

	file.track = track
	file.tags = Tags.fromItunes(fields)
	file.freeform = fields.freeform
	applyGapless(file)

	return file
end

--- Reports whether the first bytes are an ISO base media file.
---@param content string
---@return boolean
function Mp4.isValid(content)
	return #content >= 8 and content:sub(5, 8) == "ftyp"
end

return Mp4
