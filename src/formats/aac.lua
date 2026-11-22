-- AAC playback from an MP4 container through Fraunhofer FDK AAC.
--
-- The container side lives in mp4.lua: it locates each access unit and says
-- which frames are encoder priming. Here those units go straight into the
-- decoder's public C API, and the PCM it returns is handed out one frame at
-- a time.
local ffi = require("ffi")
local native = require("treble.native")
local Mp4 = require("treble.formats.mp4")

-- The decoder half of fdk-aac 2.0.3, as declared in aacdecoder_lib.h. The
-- stream info layout is copied field for field: FDK returns a pointer to it,
-- so a missing member would misread everything after it.
ffi.cdef([[
	typedef int INT;
	typedef unsigned int UINT;
	typedef unsigned char UCHAR;
	typedef signed char SCHAR;
	typedef long long INT64;
	typedef short INT_PCM;

	/* Only the transport this module uses. The enum has more members, but the
	   ABI is an int either way. */
	typedef enum {
		TT_MP4_RAW = 0
	} TRANSPORT_TYPE;

	typedef int AUDIO_OBJECT_TYPE;
	typedef int AUDIO_CHANNEL_TYPE;

	typedef struct {
		INT sampleRate;
		INT frameSize;
		INT numChannels;
		AUDIO_CHANNEL_TYPE *pChannelType;
		UCHAR *pChannelIndices;
		INT aacSampleRate;
		INT profile;
		AUDIO_OBJECT_TYPE aot;
		INT channelConfig;
		INT bitRate;
		INT aacSamplesPerFrame;
		INT aacNumChannels;
		AUDIO_OBJECT_TYPE extAot;
		INT extSamplingRate;
		UINT outputDelay;
		UINT flags;
		SCHAR epConfig;
		INT numLostAccessUnits;
		INT64 numTotalBytes;
		INT64 numBadBytes;
		INT64 numTotalAccessUnits;
		INT64 numBadAccessUnits;
		SCHAR drcProgRefLev;
		SCHAR drcPresMode;
		INT outputLoudness;
	} CStreamInfo;

	typedef struct AAC_DECODER_INSTANCE *HANDLE_AACDECODER;

	HANDLE_AACDECODER aacDecoder_Open(TRANSPORT_TYPE transportFmt, UINT nrOfLayers);
	INT aacDecoder_ConfigRaw(HANDLE_AACDECODER self, UCHAR *conf[], const UINT length[]);
	INT aacDecoder_Fill(HANDLE_AACDECODER self, UCHAR *pBuffer[], const UINT bufferSize[],
		UINT *bytesValid);
	INT aacDecoder_DecodeFrame(HANDLE_AACDECODER self, INT_PCM *pTimeData,
		const INT timeDataSize, const UINT flags);
	INT aacDecoder_SetParam(HANDLE_AACDECODER self, int param, const INT value);
	CStreamInfo *aacDecoder_GetStreamInfo(HANDLE_AACDECODER self);
	void aacDecoder_Close(HANDLE_AACDECODER self);
]])

local TT_MP4_RAW = 0

local AAC_PCM_LIMITER_ENABLE = 0x0004
local AAC_CONCEAL_METHOD = 0x0100

local AAC_DEC_OK = 0
local AAC_DEC_NOT_ENOUGH_BITS = 0x1002
local AAC_DEC_TRANSPORT_SYNC_ERROR = 0x1001
local AAC_DEC_TRANSPORT_ERROR = 0x4001

-- FDK's decode errors are concealed output: the frame is valid even though the
-- decoder had to guess at a corrupted part. Initialisation errors are not.
local DECODE_ERROR_START = 0x4000
local DECODE_ERROR_END = 0x4FFF
local ANC_DATA_ERROR_START = 0x8000
local ANC_DATA_ERROR_END = 0x8FFF

-- AAC-LC frames are 1024 samples and HE-AAC ones 2048. Eight channels covers
-- every layout the decoder returns; anything larger reports a buffer error
-- rather than reading past it.
local MAX_FRAME_SIZE = 2048
local MAX_CHANNELS = 8

---@param code number
---@return boolean
local function isOutputValid(code)
	return code == AAC_DEC_OK
		or (code >= DECODE_ERROR_START and code <= DECODE_ERROR_END)
		or (code >= ANC_DATA_ERROR_START and code <= ANC_DATA_ERROR_END)
end

---@param code number
---@return string
local function decoderMessage(code)
	if code == AAC_DEC_NOT_ENOUGH_BITS then
		return "not enough bits for a complete frame"
	elseif code == AAC_DEC_TRANSPORT_SYNC_ERROR then
		return "the AAC transport lost sync"
	elseif code == AAC_DEC_TRANSPORT_ERROR then
		return "the AAC transport rejected the frame"
	end

	return string.format("AAC decoder error 0x%04x", code)
end

---@param asc string
---@return ffi.cdata*? handle
---@return string? err
local function openDecoder(asc)
	local lib = native.lib
	local handle = lib.aacDecoder_Open(TT_MP4_RAW, 1)
	---@cast handle ffi.cdata*?

	if handle == nil then
		return nil, "Failed to open the AAC decoder"
	end

	-- FDK's defaults add a frame of concealment delay and the limiter's attack
	-- time to every output sample. Both are real playback latency, and the
	-- container's priming and sample tables know nothing about them. Turning
	-- them off makes decoded frame N line up with media frame N, which is what
	-- gapless trimming and an exact seek need. Treble has its own volume path
	-- and does not rely on FDK's limiter.
	if lib.aacDecoder_SetParam(handle, AAC_CONCEAL_METHOD, 0) ~= AAC_DEC_OK
		or lib.aacDecoder_SetParam(handle, AAC_PCM_LIMITER_ENABLE, 0) ~= AAC_DEC_OK then
		lib.aacDecoder_Close(handle)
		return nil, "Failed to configure the AAC decoder's delay settings"
	end

	local conf = ffi.new("UCHAR *[1]")
	conf[0] = ffi.cast("UCHAR *", asc)
	local length = ffi.new("UINT[1]", #asc)

	local code = lib.aacDecoder_ConfigRaw(handle, conf, length)
	if code ~= AAC_DEC_OK then
		lib.aacDecoder_Close(handle)
		return nil, "Failed to configure the AAC decoder: " .. decoderMessage(code)
	end

	return handle
end

---@class treble.formats.AacSource: treble.Source
---@field tags treble.Tags?
---@field private reader treble.formats.mp4.Reader
---@field private track treble.formats.mp4.Track
---@field private asc string
---@field private handle ffi.cdata*
---@field private buffer ffi.cdata*
---@field private bufferCapacity number
---@field private pendingOffset number # Frames already used in the decoded buffer
---@field private pendingFrames number
---@field private nextSample number # 0 based access unit to decode next
---@field private output number # Frames handed out since the track began
---@field private skipUntil number # Media frame where audible output starts
---@field private sampleIndex number? # Last access unit this source located
---@field private sampleOffset number
---@field private sampleSize number
local AacSource = {}
AacSource.__index = AacSource

---@param reader treble.formats.mp4.Reader
---@param file treble.formats.mp4.File
---@return treble.formats.AacSource? source
---@return string? err
function AacSource.new(reader, file)
	local track = assert(file.track)
	local asc = assert(track.asc)
	local handle, err = openDecoder(asc)
	if handle == nil then return nil, err end

	local capacity = MAX_FRAME_SIZE * MAX_CHANNELS

	return setmetatable({
		reader = reader,
		track = track,
		asc = asc,
		handle = handle,
		buffer = ffi.new("INT_PCM[?]", capacity),
		bufferCapacity = capacity,
		tags = file.tags,
		channels = track.channels,
		sampleRate = track.sampleRate,
		frameCount = track.frameCount,
		pendingOffset = 0,
		pendingFrames = 0,
		nextSample = 0,
		output = 0,
		skipUntil = track.priming,
		sampleIndex = nil,
		sampleOffset = 0,
		sampleSize = 0,
	}, AacSource)
end

--- Finds an access unit's bytes, reusing the sequential position when the
--- decoder asks for the next one.
---@param index number
---@return number? offset
---@return number? size
function AacSource:locate(index)
	if self.sampleIndex == index then return self.sampleOffset, self.sampleSize end

	if self.sampleIndex ~= nil and index == self.sampleIndex + 1 then
		local size = Mp4.sampleSize(self.track, index)
		if size > 0 then
			local offset = self.sampleOffset + self.sampleSize
			self.sampleIndex = index
			self.sampleSize = size
			self.sampleOffset = offset
			return offset, size
		end
	end

	local offset, size = Mp4.sampleOffset(self.track, index)
	if offset == nil or size == nil then return nil end

	self.sampleIndex = index
	self.sampleOffset = offset
	self.sampleSize = size

	return offset, size
end

--- Replaces the decoder, so a seek starts from filterbank history that the
--- following access units can settle.
---@param nextSample number
---@param skipUntil number
---@return boolean? ok
---@return string? err
function AacSource:reset(nextSample, skipUntil)
	local handle, err = openDecoder(self.asc)
	if handle == nil then return nil, err end

	if self.handle ~= nil then
		native.lib.aacDecoder_Close(self.handle)
	end

	self.handle = handle
	self.nextSample = nextSample
	self.skipUntil = skipUntil
	self.pendingOffset = 0
	self.pendingFrames = 0
	self.sampleIndex = nil

	return true
end

--- Decodes one access unit into the buffer.
---@return number? frames # 0 when there is nothing left
---@return string? err
function AacSource:decodeNext()
	local track = self.track
	if self.nextSample >= track.sampleCount then return 0 end

	local index = self.nextSample
	local offset, size = self:locate(index)
	if offset == nil or size == nil or size <= 0 then
		return nil, "The MP4 sample table points outside the file"
	end

	local data = self.reader:read(offset, size)
	if data == nil or #data < size then
		return nil, "Truncated AAC access unit in MP4 file"
	end

	self.nextSample = index + 1

	local lib = native.lib
	local input = ffi.new("UCHAR *[1]")
	input[0] = ffi.cast("UCHAR *", data)
	local inputSize = ffi.new("UINT[1]", #data)
	local remaining = ffi.new("UINT[1]", #data)

	local code = lib.aacDecoder_Fill(self.handle, input, inputSize, remaining)
	if code ~= AAC_DEC_OK then
		return nil, "Failed to feed the AAC decoder: " .. decoderMessage(code)
	end

	code = lib.aacDecoder_DecodeFrame(self.handle, self.buffer, self.bufferCapacity, 0)
	if not isOutputValid(code) then
		return nil, "Failed to decode AAC frame: " .. decoderMessage(code)
	end

	local info = lib.aacDecoder_GetStreamInfo(self.handle)
	if info == nil or info.frameSize <= 0 or info.numChannels <= 0 then
		return nil, "The AAC decoder reported no output frame"
	end

	local frames = info.frameSize
	local channels = info.numChannels

	if frames * channels > self.bufferCapacity then
		return nil, "The AAC decoder output does not fit the PCM buffer"
	end

	-- The configuration says what to expect; the decoder says what it actually
	-- produced, which is the answer worth keeping once a frame exists.
	if channels ~= self.channels or info.sampleRate ~= self.sampleRate then
		self.channels = channels
		self.sampleRate = info.sampleRate
	end

	local start = Mp4.sampleStart(track, index)
	if start >= self.skipUntil then
		self.pendingOffset = 0
		self.pendingFrames = frames
	else
		local skip = math.min(frames, self.skipUntil - start)
		self.pendingOffset = skip
		self.pendingFrames = frames - skip
	end

	return self.pendingFrames
end

---@param out ffi.cdata*
---@param frames number
---@return number? frames
---@return string? err
function AacSource:read(out, frames)
	local available = self.frameCount - self.output
	if available <= 0 then return 0 end
	if frames > available then frames = available end

	local written = 0

	while written < frames do
		if self.pendingFrames == 0 then
			local decoded, err = self:decodeNext()
			if decoded == nil then return nil, err end

			if decoded == 0 and self.nextSample >= self.track.sampleCount then
				break
			end
		end

		if self.pendingFrames > 0 then
			local take = math.min(self.pendingFrames, frames - written)
			local sampleBytes = ffi.sizeof("INT_PCM")

			ffi.copy(out + (written * self.channels),
				self.buffer + (self.pendingOffset * self.channels),
				take * self.channels * sampleBytes)

			self.pendingOffset = self.pendingOffset + take
			self.pendingFrames = self.pendingFrames - take
			written = written + take
			self.output = self.output + take
		end
	end

	return written
end

--- Seeks to a PCM frame. AAC's filterbank carries state from the previous
--- frame, so decoding starts one access unit early and the samples before the
--- target are dropped.
---@param frame number
---@return boolean
function AacSource:seek(frame)
	if self.handle == nil then return false end

	frame = math.max(0, math.min(frame, self.frameCount))
	local media = self.track.priming + frame
	local sample = Mp4.sampleAt(self.track, media)

	local ok = self:reset(math.max(0, sample - 1), media)
	if not ok then return false end

	self.output = frame
	return true
end

function AacSource:close()
	if self.handle ~= nil then
		native.lib.aacDecoder_Close(self.handle)
		self.handle = nil
	end

	if self.reader ~= nil then
		self.reader:close()
		self.reader = nil
	end
end

local Aac = {}

---@param path string
---@return treble.formats.AacSource? source
---@return string? err
function Aac.fromPath(path)
	local reader, err = Mp4.openPath(path)
	if reader == nil then return nil, err end

	local file, parseErr = Mp4.parse(reader)
	if file == nil then
		reader:close()
		return nil, parseErr
	end

	local source, sourceErr = AacSource.new(reader, file)
	if source == nil then
		reader:close()
		return nil, sourceErr
	end

	return source
end

--- Reads from memory that must stay alive until the source is closed.
---@param pointer ffi.cdata*
---@param size number
---@return treble.formats.AacSource? source
---@return string? err
function Aac.fromMemory(pointer, size)
	local reader = Mp4.memoryReader(pointer, size)

	local file, parseErr = Mp4.parse(reader)
	if file == nil then
		return nil, parseErr
	end

	local source, sourceErr = AacSource.new(reader, file)
	if source == nil then
		return nil, sourceErr
	end

	return source
end

--- Reports whether the content starts with an ISO base media `ftyp` box.
---@param content string
function Aac.isValid(content)
	return Mp4.isValid(content)
end

return Aac
