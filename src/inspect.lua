-- Reading what a file says about itself without opening a decoder.
--
-- The scan of a library asks one question per file -- what is this, how long is it, and what does
-- it say it is called -- and the answer is in the container's header. Decoder initialisation is
-- tens of times more expensive than the header read, and an album's picture is often larger than
-- the rest of its metadata put together. What this module does is therefore lengths and seeks:
-- text fields are read, picture payloads are skipped, and no audio packet is ever decoded.
--
--   local info = assert(require("treble.audio").inspect("track.flac"))
--   print(info.format, info.duration, info.tags.title, info.hasPicture)
local bit = require("bit")
local Tags = require("treble.tags")

---@class treble.audio.Inspect
---@field format string
---@field sampleRate number
---@field channels number
---@field duration number # seconds, 0 when the container cannot say
---@field tags treble.Tags? # pictures are not copied; see `hasPicture`
---@field hasPicture boolean

local inspect = {}

---@param file file*
---@param offset number
---@param count number
---@return string?
local function readAt(file, offset, count)
	if count <= 0 then return "" end

	file:seek("set", offset)
	return file:read(count)
end

---@param file file*
---@return number
local function sizeOf(file)
	local at = file:seek()
	local size = file:seek("end")

	if at ~= nil then file:seek("set", at) end

	return size
end

---@param b1 number
---@param b2 number?
---@param b3 number?
---@param b4 number?
local function be32(b1, b2, b3, b4)
	return b1 * 16777216 + (b2 or 0) * 65536 + (b3 or 0) * 256 + (b4 or 0)
end

---@param b1 number
---@param b2 number?
---@param b3 number?
---@param b4 number?
local function le32(b1, b2, b3, b4)
	return b1 + (b2 or 0) * 256 + (b3 or 0) * 65536 + (b4 or 0) * 16777216
end

---@param data string
---@param at number
local function synchsafe(data, at)
	return (data:byte(at) or 0) * 2097152 + (data:byte(at + 1) or 0) * 16384
		+ (data:byte(at + 2) or 0) * 128 + (data:byte(at + 3) or 0)
end

---@param value number
local function synchsafeBytes(value)
	return string.char(
		bit.band(bit.rshift(value, 21), 0x7F),
		bit.band(bit.rshift(value, 14), 0x7F),
		bit.band(bit.rshift(value, 7), 0x7F),
		bit.band(value, 0x7F)
	)
end

-- ────────────────────────────────────────────────────────────────
-- vorbis comments
-- ────────────────────────────────────────────────────────────────

--- Reads the vendor and the comments at a block, without copying a picture.
---@param file file*
---@param start number # the first byte of the vendor length
---@param limit number # one past the last byte of the block
---@return treble.Tags
---@return boolean hasPicture
local function vorbisComments(file, start, limit)
	local at = start
	local vendorLength = readAt(file, at, 4)

	if vendorLength == nil or #vendorLength < 4 then
		return {}, false
	end

	local vendorBytes = le32(vendorLength:byte(1), vendorLength:byte(2), vendorLength:byte(3),
		vendorLength:byte(4))
	at = at + 4

	local vendor = ""
	if vendorBytes > 0 and at + vendorBytes <= limit then
		vendor = readAt(file, at, vendorBytes) or ""
	end
	at = at + vendorBytes

	local countData = readAt(file, at, 4)
	if countData == nil or #countData < 4 then
		return Tags.fromVorbisComments({}, vendor), false
	end

	local count = le32(countData:byte(1), countData:byte(2), countData:byte(3), countData:byte(4))
	at = at + 4

	local comments = {}
	local hasPicture = false

	for _ = 1, count do
		if at + 4 > limit then break end

		local lengthData = readAt(file, at, 4)
		if lengthData == nil or #lengthData < 4 then break end

		local length = le32(lengthData:byte(1), lengthData:byte(2), lengthData:byte(3),
			lengthData:byte(4))
		at = at + 4

		if at + length > limit then
			-- A picture is usually the thing that makes a comment block run past the bounded
			-- head. What was read before it is still the answer.
			break
		end

		local value = readAt(file, at, math.min(length, 4096)) or ""
		at = at + length

		if value:sub(1, 23):upper() == "METADATA_BLOCK_PICTURE=" then
			hasPicture = true
		elseif length <= 4096 then
			comments[#comments + 1] = value
		end
	end

	return Tags.fromVorbisComments(comments, vendor), hasPicture
end

-- ────────────────────────────────────────────────────────────────
-- FLAC
-- ────────────────────────────────────────────────────────────────

local TEXT_FIELDS = { "title", "artist", "album", "albumArtist", "track", "trackCount", "disc",
	"date", "genre" }

--- A vendor alone is not a tag a library can use. What a scan wants is nothing when nothing was
--- written, not a table that asks every reader to test six fields.
---@param tags treble.Tags?
---@return treble.Tags?
local function useful(tags)
	if tags == nil then return nil end
	for _, field in ipairs(TEXT_FIELDS) do
		if tags[field] ~= nil then return tags end
	end
	return nil
end

---@param file file*
---@return treble.audio.Inspect?
local function flac(file)
	local marker = readAt(file, 0, 4)
	if marker ~= "fLaC" then return nil end

	---@type treble.audio.Inspect
	local info = { format = "FLAC", sampleRate = 0, channels = 0, duration = 0, hasPicture = false }
	local at = 4

	while true do
		local header = readAt(file, at, 4)
		if header == nil or #header < 4 then break end

		local first = header:byte(1) or 0
		local last = bit.band(first, 0x80) ~= 0
		local kind = bit.band(first, 0x7F)
		local length = (header:byte(2) or 0) * 65536 + (header:byte(3) or 0) * 256
			+ (header:byte(4) or 0)
		local body = at + 4

		if kind == 0 and length >= 18 then
			local stream = readAt(file, body, 18)
			if stream ~= nil and #stream >= 18 then
				local high = be32(stream:byte(11), stream:byte(12), stream:byte(13), stream:byte(14))
				local low = be32(stream:byte(15), stream:byte(16), stream:byte(17), stream:byte(18))

				info.sampleRate = bit.band(bit.rshift(high, 12), 0xFFFFF)
				info.channels = bit.band(bit.rshift(high, 9), 0x7) + 1

				local total = bit.band(high, 0xF) * 4294967296 + low
				if info.sampleRate > 0 then info.duration = total / info.sampleRate end
			end
		elseif kind == 4 then
			local tags, hasPicture = vorbisComments(file, body, body + length)
			info.tags = useful(tags)
			info.hasPicture = info.hasPicture or hasPicture
		elseif kind == 6 then
			info.hasPicture = true
		end

		at = body + length
		if last then break end
	end

	return info
end

-- ────────────────────────────────────────────────────────────────
-- WAV
-- ────────────────────────────────────────────────────────────────

local WAV_TAGS = {
	INAM = "title",
	IART = "artist",
	IPRD = "album",
	ICRD = "date",
	IGNR = "genre",
	ICMT = "comment",
	ITRK = "track",
	IPRT = "track",
}

---@param file file*
---@return treble.audio.Inspect?
local function wav(file)
	local header = readAt(file, 0, 12)
	if header == nil or #header < 12 or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
		return nil
	end

	---@type treble.audio.Inspect
	local info = { format = "WAV", sampleRate = 0, channels = 0, duration = 0, hasPicture = false }
	---@type treble.Tags
	local tags = {}

	local at = 12
	local total = sizeOf(file)
	local bits = 0
	local dataSize = nil

	while at + 8 <= total do
		local chunk = readAt(file, at, 8)
		if chunk == nil or #chunk < 8 then break end

		local id = chunk:sub(1, 4)
		local length = le32(chunk:byte(5), chunk:byte(6), chunk:byte(7), chunk:byte(8))
		local body = at + 8

		if id == "fmt " and length >= 16 then
			local fmt = readAt(file, body, math.min(length, 16))
			if fmt ~= nil and #fmt >= 16 then
				info.channels = (fmt:byte(4) or 0) * 256 + (fmt:byte(3) or 0)
				info.sampleRate = le32(fmt:byte(5), fmt:byte(6), fmt:byte(7), fmt:byte(8))
				bits = (fmt:byte(16) or 0) * 256 + (fmt:byte(15) or 0)
			end
		elseif id == "data" then
			dataSize = length
		elseif id == "LIST" and length >= 4 then
			local kind = readAt(file, body, 4)
			if kind == "INFO" then
				local sub = body + 4
				local stop = math.min(body + length, total)
				while sub + 8 <= stop do
					local entry = readAt(file, sub, 8)
					if entry == nil or #entry < 8 then break end
					local key = entry:sub(1, 4)
					local size = le32(entry:byte(5), entry:byte(6), entry:byte(7), entry:byte(8))
					local valueAt = sub + 8
					local field = WAV_TAGS[key]
					if field ~= nil and size > 0 and size <= 4096 then
						local value = readAt(file, valueAt, size) or ""
						value = value:gsub("%z.*$", ""):gsub("%s+$", "")
						if field == "track" then
							tags.track = tonumber(value:match("%d+"))
						else
							tags[field] = value
						end
					end
					sub = valueAt + size + (size % 2)
				end
			end
		end

		at = body + length + (length % 2)
	end

	if dataSize ~= nil and info.sampleRate > 0 and info.channels > 0 and bits > 0 then
		info.duration = dataSize / (info.sampleRate * info.channels * (bits / 8))
	end

	if next(tags) ~= nil then info.tags = tags end

	return info
end

-- ────────────────────────────────────────────────────────────────
-- MP3
-- ────────────────────────────────────────────────────────────────

-- Kilobits per second by bitrate index, for each MPEG version and layer. MPEG-2 and 2.5 share one
-- set, and in it Layers II and III share one table.
local BITRATES = {
	[1] = {
		[1] = { 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 },
		[2] = { 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 },
		[3] = { 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 },
	},
	[2] = {
		[1] = { 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256 },
		[2] = { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
		[3] = { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
	},
}

local SAMPLE_RATES = {
	[1] = { 44100, 48000, 32000 },
	[2] = { 22050, 24000, 16000 },
	[3] = { 11025, 12000, 8000 },
}

---@param head string
---@param at number zero based offset of the frame
---@return number? sampleRate
---@return number? channels
---@return number? bitrate
---@return number? frameLength
---@return number? samplesPerFrame
local function mpegFrame(head, at)
	if #head < at + 4 then return nil end

	local b1, b2, b3, b4 = head:byte(at + 1), head:byte(at + 2), head:byte(at + 3), head:byte(at + 4)
	if b1 ~= 0xFF or b2 == nil or bit.band(b2, 0xE0) ~= 0xE0 then return nil end

	local versionBits = bit.band(bit.rshift(b2, 3), 0x3)
	local layerBits = bit.band(bit.rshift(b2, 1), 0x3)
	local version = versionBits == 3 and 1 or (versionBits == 2 and 2 or (versionBits == 0 and 3 or nil))
	local layer = layerBits == 3 and 1 or (layerBits == 2 and 2 or (layerBits == 1 and 3 or nil))
	if version == nil or layer == nil then return nil end

	local bitrateIndex = bit.band(bit.rshift(b3, 4), 0xF)
	local rateIndex = bit.band(bit.rshift(b3, 2), 0x3)
	local bitrate = BITRATES[version == 1 and 1 or 2][layer][bitrateIndex + 1]
	local sampleRate = SAMPLE_RATES[version] and SAMPLE_RATES[version][rateIndex + 1]
	if bitrate == nil or bitrate == 0 or sampleRate == nil then return nil end

	local padding = bit.band(bit.rshift(b3, 1), 0x1)
	local channels = bit.band(bit.rshift(b4, 6), 0x3) == 3 and 1 or 2
	local frameLength

	if layer == 1 then
		frameLength = math.floor(12 * bitrate * 1000 / sampleRate + padding) * 4
	elseif layer == 2 then
		frameLength = math.floor(144 * bitrate * 1000 / sampleRate + padding)
	else
		frameLength = math.floor((version == 1 and 144 or 72) * bitrate * 1000 / sampleRate + padding)
	end

	-- Layer I frames hold 384 samples, and a Layer III frame of MPEG-2 or 2.5 holds half of 1152.
	local samplesPerFrame = layer == 1 and 384 or ((layer == 3 and version ~= 1) and 576 or 1152)
	return sampleRate, channels, bitrate, frameLength, samplesPerFrame
end

-- How much of a stream is read at a time while its frames are counted.
local COUNT_BLOCK = 1048576

--- The frames from the first one to the end of the stream, counted by their headers alone: each
--- says how long it is, so the next one is found without decoding anything. The stream ends at
--- the first thing that is not a frame, which is a tag at the end of the file.
---@param file file*
---@param first number byte offset of the first frame
---@param total number
---@return number frames
local function countFrames(file, first, total)
	local frames = 0
	local at = first
	local block, blockAt = "", first

	while at + 4 <= total do
		if at + 4 > blockAt + #block then
			blockAt = at
			block = readAt(file, at, math.min(COUNT_BLOCK, total - at)) or ""
		end

		local _, _, _, frameLength = mpegFrame(block, at - blockAt)
		if frameLength == nil or frameLength <= 0 then break end

		frames = frames + 1
		at = at + frameLength
	end

	return frames
end

---@param file file*
---@param start number
---@param total number
---@return number? duration
---@return number? sampleRate
---@return number? channels
local function mp3Duration(file, start, total)
	local head = readAt(file, start, math.min(8192, total - start)) or ""
	local at = 0
	local found = nil

	while at + 4 <= #head do
		local sampleRate, channels, bitrate, frameLength, samplesPerFrame = mpegFrame(head, at)
		if sampleRate ~= nil then
			found = {
				sampleRate = sampleRate,
				channels = channels,
				bitrate = bitrate,
				frameLength = frameLength,
				samplesPerFrame = samplesPerFrame,
				offset = at,
			}
			break
		end
		at = at + 1
	end

	if found == nil then return nil end
	---@cast found table

	-- Xing/Info and VBRI state the whole file's frame count in the first frame.
	local frame = readAt(file, start + found.offset, found.frameLength or 0) or ""
	local side
	if found.sampleRate >= 32000 then
		side = found.channels == 1 and 17 or 32
	else
		side = found.channels == 1 and 9 or 17
	end
	local xingAt = 4 + side + 1

	if frame:sub(xingAt, xingAt + 3) == "Xing" or frame:sub(xingAt, xingAt + 3) == "Info" then
		local flags = be32(frame:byte(xingAt + 4), frame:byte(xingAt + 5), frame:byte(xingAt + 6),
			frame:byte(xingAt + 7))
		if bit.band(flags, 0x1) ~= 0 then
			local frames = be32(frame:byte(xingAt + 8), frame:byte(xingAt + 9),
				frame:byte(xingAt + 10), frame:byte(xingAt + 11))
			if frames > 0 then
				return frames * assert(found.samplesPerFrame) / found.sampleRate, found.sampleRate,
					found.channels
			end
		end
	end

	if frame:sub(37, 40) == "VBRI" then
		local frames = be32(frame:byte(51), frame:byte(52), frame:byte(53), frame:byte(54))
		if frames > 0 then
			return frames * assert(found.samplesPerFrame) / found.sampleRate, found.sampleRate,
				found.channels
		end
	end

	-- With neither, the frames are counted: a stream of one bitrate could be worked out from its
	-- size, but one whose bitrate varies cannot, and nothing before the end says which it is.
	local frames = countFrames(file, start + found.offset, total)
	return frames * assert(found.samplesPerFrame) / found.sampleRate, found.sampleRate, found.channels
end

---@param file file*
---@return treble.audio.Inspect?
local function mp3(file)
	local header = readAt(file, 0, 10)
	if header == nil then return nil end

	local hasPicture = false
	local id3Tags = nil
	local at = 0

	if header:sub(1, 3) == "ID3" and #header >= 10 then
		local major = header:byte(4) or 3
		local tagSize = synchsafe(header, 7)
		local body = 10
		local stop = body + tagSize
		local frames = {}
		local frameBytes = 0
		local pos = body

		while pos + 6 <= stop do
			local frameHeader = readAt(file, pos, major == 2 and 6 or 10)
			if frameHeader == nil or frameHeader:byte(1) == 0 then break end

			local id, frameSize, headerSize
			if major == 2 then
				id = frameHeader:sub(1, 3)
				frameSize = be32(0, frameHeader:byte(4), frameHeader:byte(5), frameHeader:byte(6))
				headerSize = 6
			else
				id = frameHeader:sub(1, 4)
				frameSize = major == 4 and synchsafe(frameHeader, 5)
					or be32(frameHeader:byte(5), frameHeader:byte(6), frameHeader:byte(7),
						frameHeader:byte(8))
				headerSize = 10
			end

			if frameSize <= 0 or pos + headerSize + frameSize > stop then break end

			if id == "APIC" or id == "PIC" then
				hasPicture = true
			else
				local value = readAt(file, pos + headerSize, frameSize) or ""
				frames[#frames + 1] = frameHeader .. value
				frameBytes = frameBytes + headerSize + #value
			end

			pos = pos + headerSize + frameSize
		end

		local payload = table.concat(frames)
		if #payload > 0 then
			local synthetic = "ID3" .. string.char(major, 0) .. string.char(0)
				.. synchsafeBytes(#payload) .. payload
			id3Tags = Tags.fromId3v2(synthetic)
		end

		at = stop
	end

	if #header < 3 or header:sub(1, 3) ~= "ID3" then
		-- A bare MPEG stream starts at the first frame.
		at = 0
	end

	local total = sizeOf(file)

	if at == 0 then
		-- The first frame may not be at byte zero even without a tag; find it.
		local head = readAt(file, 0, math.min(65536, total)) or ""
		for index = 0, #head - 4 do
			if mpegFrame(head, index) ~= nil then
				at = index
				break
			end
		end
	end

	local duration, sampleRate, channels = mp3Duration(file, at, total)

	if id3Tags == nil then
		-- ID3v1 lives in the last 128 bytes.
		if total >= 128 then
			local footer = readAt(file, total - 128, 128)
			if footer ~= nil then
				id3Tags = Tags.fromId3v1(footer)
			end
		end
	end

	if sampleRate == nil then return nil end

	---@type treble.audio.Inspect
	return {
		format = "MP3",
		sampleRate = sampleRate,
		channels = channels or 2,
		duration = duration or 0,
		tags = id3Tags or nil,
		hasPicture = hasPicture,
	}
end

-- ────────────────────────────────────────────────────────────────
-- Ogg Opus
-- ────────────────────────────────────────────────────────────────

---@param data string
---@return treble.Tags?
---@return boolean
local function opusTags(data)
	if data:sub(1, 8) ~= "OpusTags" then return nil, false end

	local at = 9
	local vendorLength = le32(data:byte(at), data:byte(at + 1), data:byte(at + 2), data:byte(at + 3))
	at = at + 4

	local vendor = data:sub(at, at + vendorLength - 1)
	at = at + vendorLength

	if at + 4 > #data then return Tags.fromVorbisComments({}, vendor), false end

	local count = le32(data:byte(at), data:byte(at + 1), data:byte(at + 2), data:byte(at + 3))
	at = at + 4

	local comments = {}
	local hasPicture = false

	for _ = 1, count do
		if at + 4 > #data then break end
		local length = le32(data:byte(at), data:byte(at + 1), data:byte(at + 2), data:byte(at + 3))
		at = at + 4

		if at + length - 1 > #data then
			-- The picture is the usual reason this runs past the head. Its four-byte length
			-- is still here even when its payload is not, so read enough of the value to name
			-- it before stopping: the cover is exactly what the view asked about.
			if data:sub(at, at + 22):upper() == "METADATA_BLOCK_PICTURE=" then hasPicture = true end
			break
		end

		local value = data:sub(at, at + length - 1)
		at = at + length

		if value:sub(1, 23):upper() == "METADATA_BLOCK_PICTURE=" then
			hasPicture = true
		else
			comments[#comments + 1] = value
		end
	end

	return Tags.fromVorbisComments(comments, vendor), hasPicture
end

---@param file file*
---@param limit number
---@return treble.audio.Inspect?
local function opus(file, limit)
	local total = sizeOf(file)
	local headData = readAt(file, 0, math.min(limit, total))
	if headData == nil or headData:sub(1, 4) ~= "OggS" then return nil end

	local at = 1
	local preSkip = 0
	local channels = 2
	local packetIndex = 0
	local packet = {}

	---@param tags treble.Tags?
	---@param hasPicture boolean
	---@return treble.audio.Inspect
	local function finish(tags, hasPicture)
		local tailAt = math.max(0, total - 8192)
		local tail = readAt(file, tailAt, total - tailAt) or ""
		local last = nil
		local search = 1
		while search <= #tail - 3 do
			local found = tail:find("OggS", search, true)
			if found == nil then break end
			last = found
			search = found + 4
		end

		-- A page may be larger than the first tail read -- a picture is one packet -- so a tail
		-- with no page header in it is read again at the largest page size.
		if last == nil and total > 8192 then
			tailAt = math.max(0, total - 66048)
			tail = readAt(file, tailAt, total - tailAt) or ""
			search = 1
			while search <= #tail - 3 do
				local found = tail:find("OggS", search, true)
				if found == nil then break end
				last = found
				search = found + 4
			end
		end

		local duration = 0
		if last ~= nil and last + 13 <= #tail then
			local high = le32(tail:byte(last + 10), tail:byte(last + 11),
				tail:byte(last + 12), tail:byte(last + 13))
			local low = le32(tail:byte(last + 6), tail:byte(last + 7),
				tail:byte(last + 8), tail:byte(last + 9))
			local granule = high * 4294967296 + low
			if not (high == 0xFFFFFFFF and low == 0xFFFFFFFF) then
				duration = math.max(0, (granule - preSkip) / 48000)
			end
		end

		return {
			format = "Opus",
			sampleRate = 48000,
			channels = channels,
			duration = duration,
			tags = useful(tags),
			hasPicture = hasPicture,
		}
	end

	local function tryTags(data)
		if data:sub(1, 8) ~= "OpusTags" then return nil end
		local tags, hasPicture = opusTags(data)
		if useful(tags) ~= nil then return finish(tags, hasPicture) end
		return nil, hasPicture
	end

	---@param data string
	---@return boolean
	local function takePacket(data)
		packetIndex = packetIndex + 1
		if packetIndex == 1 and data:sub(1, 8) == "OpusHead" then
			channels = data:byte(10) or 2
			preSkip = (data:byte(11) or 0) + (data:byte(12) or 0) * 256
		end
		return packetIndex == 2 and data:sub(1, 8) == "OpusTags"
	end

	while at + 26 <= #headData do
		if headData:sub(at, at + 3) ~= "OggS" then break end
		local pageAt = at

		local segments = headData:byte(pageAt + 26) or 0
		local tableAt = pageAt + 27
		local payloadAt = tableAt + segments
		local completed = false

		if payloadAt - 1 > #headData then break end

		for index = 0, segments - 1 do
			local length = headData:byte(tableAt + index) or 0
			local bytes = headData:sub(payloadAt, payloadAt + length - 1)
			payloadAt = payloadAt + length

			packet[#packet + 1] = bytes

			if length < 255 then
				local whole = table.concat(packet)
				local isTags = takePacket(whole)
				packet = {}

				if isTags then
					local tags, hasPicture = opusTags(whole)
					return finish(tags, hasPicture)
				end

				if packetIndex >= 2 then
					-- The comments packet is behind us. Nothing later in the head is a tag.
					completed = true
					break
				end
			end
		end

		-- A picture can make the comment packet larger than any head worth reading. The text
		-- tags are at the front, so one parse per page is enough to find them and stop early.
		if not completed and packetIndex == 1 and #packet > 0 then
			local found = tryTags(table.concat(packet))
			if found ~= nil then return found end
		end

		if completed then break end

		at = payloadAt
	end

	return nil
end

-- ────────────────────────────────────────────────────────────────
-- entry point
-- ────────────────────────────────────────────────────────────────

--- What a file says about itself, without opening a decoder.
---
--- The tags this returns have no picture in them; `hasPicture` says whether one is there. Read
--- the picture with `treble.audio.tags` when a view wants it.
---@param path string
---@return treble.audio.Inspect? info
---@return string? err
function inspect.inspect(path)
	local file, err = io.open(path, "rb")
	if file == nil then
		return nil, "Failed to open audio file: " .. tostring(err)
	end

	local magic = file:read(4) or ""
	file:seek("set", 0)

	local result = nil
	if magic == "fLaC" then
		result = flac(file)
	elseif magic == "RIFF" then
		result = wav(file)
	elseif magic:sub(1, 3) == "ID3" or magic:sub(1, 2) == "\255\251"
		or (magic:byte(1) == 0xFF and magic:byte(2) ~= nil and magic:byte(2) >= 0xE0) then
		result = mp3(file)
	elseif magic == "OggS" then
		result = opus(file, 8192)
		-- A cover can push the comment packet past the first head. The text still comes back
		-- from the short read, but `hasPicture` needs the larger window to see its comment
		-- length, so ask again before calling the track artless.
		if result == nil or not result.hasPicture then
			local larger = opus(file, 65536)
			if larger ~= nil and (result == nil or larger.hasPicture) then result = larger end
		end
	end

	file:close()

	if result == nil then
		return nil, "Unsupported or malformed audio file: " .. path
	end

	return result
end

return inspect
