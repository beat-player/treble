-- WAV decoding.
--
-- The header is parsed from a few small reads and the samples are only touched
-- when they are asked for, so both a file on a slow network mount and a buffer
-- already in memory work without loading a whole track.
local ffi = require("ffi")

local RIFF_HEADER_SIZE = 12
local CHUNK_HEADER_SIZE = 8
local PCM = 1
local IEEE_FLOAT = 3
local EXTENSIBLE = 0xFFFE

-- Enough for the header of any normal file, small enough to be one read when the
-- file lives on a slow mount.
local HEAD_SIZE = 4096
local MAX_HEAD_SIZE = 1048576

---@class treble.formats.wav.Info
---@field dataOffset number # Bytes from the start of the file to the first frame
---@field dataLen number
---@field channels number
---@field sampleRate number
---@field bitsPerSample number
---@field isFloat boolean
---@field tags treble.Tags?

-- The INFO sub chunk of a LIST chunk, which is where a wav keeps its text.
local INFO_FIELDS = {
	INAM = "title",
	IART = "artist",
	IPRD = "album",
	ICRD = "date",
	IGNR = "genre",
	ICMT = "comment",
	ITRK = "track",
	IPRT = "track",
}

---@param pointer ffi.cdata*
---@param body number
---@param size number # How much of the chunk is inside the buffer we hold
---@return treble.Tags?
local function parseInfo(pointer, body, size)
	if size < body + 4 or ffi.string(pointer + body, 4) ~= "INFO" then
		return nil
	end

	---@type treble.Tags
	local tags = {}
	local offset = body + 4

	while offset + 8 <= size do
		local id = ffi.string(pointer + offset, 4)
		local chunkSize = ffi.cast("const uint32_t*", pointer + offset + 4)[0]
		local value = string.sub(ffi.string(pointer + offset + 8, math.min(chunkSize, size - offset - 8)), 1, chunkSize)
		local field = INFO_FIELDS[id]

		if field == "track" then
			tags.track = tonumber((value:gsub("%z.*$", ""):match("%d+")))
		elseif field ~= nil then
			---@diagnostic disable-next-line: assign-type-mismatch
			tags[field] = (value:gsub("%z.*$", ""):gsub("%s+$", ""))
		end

		offset = offset + 8 + chunkSize + chunkSize % 2
	end

	return tags
end

---@param pointer ffi.cdata*
---@param offset number
---@return string id
---@return number size
local function readChunkHeader(pointer, offset)
	return ffi.string(pointer + offset, 4), ffi.cast("const uint32_t*", pointer + offset + 4)[0]
end

--- Walks the chunk headers of a RIFF file to find the format and the sample data.
---@param pointer ffi.cdata*
---@param size number # how much of the file is in the buffer
---@param total number? # how large the whole file is, when the header is only a prefix
---@return treble.formats.wav.Info? info
---@return string? err
local function parse(pointer, size, total)
	total = total or size
	if size < RIFF_HEADER_SIZE + CHUNK_HEADER_SIZE then
		return nil, "Truncated WAV file"
	end

	if ffi.string(pointer, 4) ~= "RIFF" or ffi.string(pointer + 8, 4) ~= "WAVE" then
		return nil, "Unsupported audio format"
	end

	---@type treble.formats.wav.Info
	local info = {
		dataOffset = 0,
		dataLen = 0,
		channels = 0,
		sampleRate = 0,
		bitsPerSample = 0,
		isFloat = false,
		tags = nil,
	}

	local format = 0
	local offset = RIFF_HEADER_SIZE

	while offset + CHUNK_HEADER_SIZE <= size do
		local id, chunkSize = readChunkHeader(pointer, offset)
		local body = offset + CHUNK_HEADER_SIZE

		if id == "fmt " then
			format = ffi.cast("const uint16_t*", pointer + body)[0]
			info.channels = ffi.cast("const uint16_t*", pointer + body + 2)[0]
			info.sampleRate = ffi.cast("const uint32_t*", pointer + body + 4)[0]
			info.bitsPerSample = ffi.cast("const uint16_t*", pointer + body + 14)[0]

			-- An extensible header names its real encoding in the first two bytes
			-- of the sub format GUID that ends the chunk.
			if format == EXTENSIBLE and chunkSize >= 40 then
				format = ffi.cast("const uint16_t*", pointer + body + 24)[0]
			end
		elseif id == "LIST" then
			info.tags = info.tags or parseInfo(pointer, body, size)
		elseif id == "data" then
			info.dataOffset = body
			-- A size that claims more than the file holds would read past the end of
			-- it, so it is clamped to what is really there.
			info.dataLen = math.min(chunkSize, total - body)
			break
		end

		-- Chunks are padded to an even length.
		offset = body + chunkSize + chunkSize % 2
	end

	if info.sampleRate == 0 or info.channels == 0 or info.bitsPerSample == 0 then
		return nil, "WAV file has no format chunk"
	end

	if info.dataOffset == 0 or info.dataLen == 0 then
		return nil, "Data chunk not found in WAV file"
	end

	if format ~= PCM and format ~= IEEE_FLOAT then
		return nil, "Unsupported WAV encoding: " .. format
	end

	info.isFloat = format == IEEE_FLOAT

	return info
end

--- Takes the top two bytes of a little endian sample, which is the sample scaled to
--- the 16 bit range, and sign extends them.
---@param low number
---@param high number
---@return number
local function signExtend(low, high)
	local value = low | (high << 8)

	return value >= 0x8000 ? value - 0x10000 : value
end

--- Scales raw samples into signed 16 bit, in place of a copy.
---@param out ffi.cdata*
---@param raw ffi.cdata*
---@param count number # Samples, not frames
---@param bytesPerSample number
---@param isFloat boolean
local function convert(out, raw, count, bytesPerSample, isFloat)
	if isFloat then
		local values = ffi.cast("const float*", raw)
		for i = 0, count - 1 do
			local value = values[i]
			out[i] = math.floor((value > 1 ? 1 : value < -1 ? -1 : value) * 32767)
		end
	elseif bytesPerSample == 1 then
		-- 8 bit PCM is unsigned, centered on 128.
		local bytes = ffi.cast("const uint8_t*", raw)
		for i = 0, count - 1 do
			out[i] = signExtend(0, bytes[i] - 128)
		end
	else
		local bytes = ffi.cast("const uint8_t*", raw)
		for i = 0, count - 1 do
			local high = i * bytesPerSample
			out[i] = signExtend(bytes[high + bytesPerSample - 2], bytes[high + bytesPerSample - 1])
		end
	end
end

---@class treble.formats.WavSource: treble.Source
---@field samples ffi.cdata*? # Only set for memory backed sources
---@field file file*? # Only set for file backed sources
---@field chunk string.buffer? # Held so a memory backed file stays mapped
---@field info treble.formats.wav.Info
---@field cursor number
---@field bytesPerFrame number
---@field bytesPerSample number
local WavSource = {}
WavSource.__index = WavSource

--- Points at the raw sample bytes for the next frames, from memory or the file.
---@param source treble.formats.WavSource
---@param frames number
---@return string|ffi.cdata*? raw
---@return number bytes
---@return string? err
local function fetchRaw(source, frames)
	local bytes = frames * source.bytesPerFrame
	if bytes == 0 then
		return nil, 0
	end

	if source.samples ~= nil then
		return source.samples + source.cursor * source.bytesPerFrame, bytes
	end

	local raw, err = source.file:read(bytes)
	if raw == nil then
		return nil, 0, err or "Failed to read audio data"
	end

	-- Keep the string itself: a pointer cast from it does not keep it alive, and
	-- the caller copies from it after this function returns.
	return raw, #raw
end

---@param out ffi.cdata*
---@param frames number
---@return number? frames # nil when the read failed
---@return string? err
function WavSource:read(out, frames)
	local available = self.frameCount - self.cursor
	if available <= 0 then
		return 0
	end

	if frames > available then
		frames = available
	end

	local raw, bytes, err = fetchRaw(self, frames)
	if raw == nil then
		if bytes == 0 and err == nil then
			return 0
		end

		return nil, err
	end

	-- A short read means the file ended early, which is a readable amount of audio.
	local read = math.floor(bytes / self.bytesPerFrame)
	self.cursor = self.cursor + read

	if self.bytesPerSample == 2 and not self.info.isFloat then
		ffi.copy(out, raw, read * self.bytesPerFrame)
	else
		convert(out, raw, read * self.info.channels, self.bytesPerSample, self.info.isFloat)
	end

	return read
end

---@param frame number
---@return boolean? ok
---@return string? err
function WavSource:seek(frame)
	local target = math.max(0, math.min(frame, self.frameCount))

	if self.samples == nil then
		local offset = self.info.dataOffset + target * self.bytesPerFrame
		local position, err = self.file:seek("set", offset)
		if position == nil then
			return nil, "Failed to seek in audio file: " .. tostring(err)
		end
	end

	self.cursor = target

	return true
end

function WavSource:close()
	if self.file ~= nil then
		self.file:close()
		self.file = nil
	end

	self.chunk = nil
end

---@param info treble.formats.wav.Info
---@return treble.formats.WavSource
local function create(info)
	local bytesPerSample = info.bitsPerSample / 8

	---@type treble.formats.WavSource
	local source = setmetatable({
		info = info,
		tags = info.tags,
		cursor = 0,
		bytesPerSample = bytesPerSample,
		bytesPerFrame = info.channels * bytesPerSample,
		channels = info.channels,
		sampleRate = info.sampleRate,
		frameCount = math.floor(info.dataLen / (info.channels * bytesPerSample)),
		samples = nil,
		file = nil,
		chunk = nil,
	}, WavSource)

	return source
end

local Wav = {}

--- Reads a file as it plays, so a long file on a slow mount costs one header read.
---@param path string
---@return treble.formats.WavSource? source
---@return string? err
function Wav.fromPath(path)
	local file, openErr = io.open(path, "rb")
	if not file then
		return nil, "Failed to open audio file: " .. tostring(openErr)
	end

	local fileSize = file:seek("end")
	if fileSize == nil then
		file:close()
		return nil, "Failed to measure audio file"
	end

	file:seek("set", 0)
	local head = file:read(HEAD_SIZE)
	if head == nil then
		file:close()
		return nil, "Failed to read audio file header"
	end

	local info, err = parse(ffi.cast("const char*", head), #head, fileSize)

	-- A file with large chunks before its samples needs a longer look at the
	-- header. The search is capped, because reading a whole file to find the start
	-- of its audio is exactly what a slow mount cannot afford.
	while info == nil and #head < MAX_HEAD_SIZE do
		local more = file:read(#head)
		if more == nil or #more == 0 then
			break
		end

		head = head .. more
		info, err = parse(ffi.cast("const char*", head), #head, fileSize)
	end

	if info == nil then
		file:close()
		return nil, err
	end

	local source = create(info)
	source.file = file

	if not source:seek(0) then
		file:close()
		return nil, "Failed to reach the audio data"
	end

	return source
end

--- Reads from memory that must stay alive until the source is closed.
---@param pointer ffi.cdata*
---@param size number
---@return treble.formats.WavSource? source
---@return string? err
function Wav.fromMemory(pointer, size)
	local samples = ffi.cast("const char*", pointer)

	local info, err = parse(samples, size)
	if info == nil then
		return nil, err
	end

	local source = create(info)
	source.samples = samples + info.dataOffset

	return source
end

--- Reports whether the content is a RIFF file this decoder accepts.
---@param content string
function Wav.isValid(content)
	return #content >= RIFF_HEADER_SIZE
		and string.sub(content, 1, 4) == "RIFF"
		and string.sub(content, 9, 12) == "WAVE"
end

return Wav
