-- Android output through AAudio.
--
-- AAudio is the NDK's native playback API, available from Android 8.0 (API 26).
-- One stream stays open for as long as the player has something to play, and the
-- stream is opened without a data callback, so this side keeps the same push model
-- as the other backends: ask how much fits, write that much, and let AAudio's
-- frame counters answer where playback is.
local ffi = require("ffi")

ffi.cdef([[
	typedef struct AAudioStreamStruct AAudioStream;
	typedef struct AAudioStreamBuilderStruct AAudioStreamBuilder;

	int32_t AAudio_createStreamBuilder(AAudioStreamBuilder **builder);
	void AAudioStreamBuilder_delete(AAudioStreamBuilder *builder);
	void AAudioStreamBuilder_setDeviceId(AAudioStreamBuilder *builder, int32_t deviceId);
	void AAudioStreamBuilder_setDirection(AAudioStreamBuilder *builder, int32_t direction);
	void AAudioStreamBuilder_setSharingMode(AAudioStreamBuilder *builder, int32_t sharingMode);
	void AAudioStreamBuilder_setFormat(AAudioStreamBuilder *builder, int32_t format);
	void AAudioStreamBuilder_setChannelCount(AAudioStreamBuilder *builder, int32_t channelCount);
	void AAudioStreamBuilder_setSampleRate(AAudioStreamBuilder *builder, int32_t sampleRate);
	void AAudioStreamBuilder_setBufferCapacityInFrames(AAudioStreamBuilder *builder, int32_t numFrames);
	void AAudioStreamBuilder_setPerformanceMode(AAudioStreamBuilder *builder, int32_t mode);
	int32_t AAudioStreamBuilder_openStream(AAudioStreamBuilder *builder, AAudioStream **stream);

	int32_t AAudioStream_close(AAudioStream *stream);
	int32_t AAudioStream_requestStart(AAudioStream *stream);
	int32_t AAudioStream_requestPause(AAudioStream *stream);
	int32_t AAudioStream_requestFlush(AAudioStream *stream);
	int32_t AAudioStream_requestStop(AAudioStream *stream);
	int32_t AAudioStream_getState(AAudioStream *stream);
	int32_t AAudioStream_waitForStateChange(
		AAudioStream *stream,
		int32_t inputState,
		int32_t *nextState,
		int64_t timeoutNanoseconds
	);
	int32_t AAudioStream_write(
		AAudioStream *stream,
		const void *buffer,
		int32_t numFrames,
		int64_t timeoutNanoseconds
	);
	int32_t AAudioStream_getBufferCapacityInFrames(AAudioStream *stream);
	int32_t AAudioStream_setBufferSizeInFrames(AAudioStream *stream, int32_t numFrames);
	int32_t AAudioStream_getFramesPerBurst(AAudioStream *stream);
	int64_t AAudioStream_getFramesWritten(AAudioStream *stream);
	int64_t AAudioStream_getFramesRead(AAudioStream *stream);
	int32_t AAudioStream_getSampleRate(AAudioStream *stream);
	int32_t AAudioStream_getChannelCount(AAudioStream *stream);
	const char *AAudio_convertResultToText(int32_t result);

	int usleep(unsigned int microseconds);
]])

-- The versioned soname is what Android ships. A missing library is reported when
-- playback is asked for rather than making the module fail to load, so tag reading
-- and decoding still work on a device without it.
---@type ffi.namespace*?
local aaudio = nil

do
	local isLoaded, library = pcall(ffi.load, "aaudio")
	if isLoaded then
		aaudio = library
	end
end

---@class treble.raw.aaudio
---@field open fun(sampleRate: number, channels: number, device: string?): treble.OutputStream?, string?
local lib = {}

--- Whether the device has AAudio: Android 8.0 and later do, and nothing else does.
---@return boolean
function lib.available()
	return aaudio ~= nil
end

local DIRECTION_OUTPUT = 0

local SHARING_MODE_SHARED = 1

local FORMAT_PCM_I16 = 1

local PERFORMANCE_MODE_POWER_SAVING = 11

local STATE_UNINITIALIZED = 0
local STATE_STARTING = 3
local STATE_STARTED = 4
local STATE_PAUSING = 5
local STATE_PAUSED = 6
local STATE_FLUSHING = 7
local STATE_FLUSHED = 8
local STATE_STOPPING = 9
local STATE_STOPPED = 10

-- Long enough that a busy frame does not starve the device, short enough that a
-- seek does not have a quarter second of stale audio to throw away. This matches
-- the other backends.
local DEVICE_LATENCY_SECONDS = 0.15

-- How long a state change may take before the call gives up. The control calls are
-- asynchronous; waiting for the state they ask for is what keeps flush and pause
-- from returning while the device is still playing.
local STATE_TIMEOUT_NS = 100000000
local STATE_STEPS = 10

local BuilderPointer = ffi.typeof("AAudioStreamBuilder*[1]")
local StreamPointer = ffi.typeof("AAudioStream*[1]")
local StateValue = ffi.typeof("int32_t[1]")

---@class treble.raw.aaudio.Stream: treble.OutputStream
---@field sampleRate number
---@field channels number
---@field private handle treble.ffi.aaudioStream
---@field private library ffi.namespace*
---@field private capacity number # Frames the stream can hold
---@field private written number # Frames written in the current timeline
---@field private readBase number # AAudio's read counter when the timeline began
---@field private isStarted boolean
---@field private isPaused boolean
local Stream = {}
Stream.__index = Stream

---@param result number
---@return string
local function errorText(result)
	local message = aaudio ~= nil and ffi.string(aaudio.AAudio_convertResultToText(result)) or "unknown error"

	return string.format("%s (%d)", message, result)
end

--- Waits until the stream reaches `target`, giving up after a short while. AAudio's
--- control calls only start a transition; writing to a stream whose pause or flush
--- is still in flight fails.
---@param stream treble.raw.aaudio.Stream
---@param target number
---@return boolean reached
local function waitForState(stream, target)
	local handle = stream.handle
	local library = stream.library
	local value = StateValue()
	local state = library.AAudioStream_getState(handle)

	for _ = 1, STATE_STEPS do
		if state == target then
			return true
		end

		-- The states a transition passes through still take writes of their own.
		if state == STATE_UNINITIALIZED or state == STATE_STOPPED then
			return false
		end

		local result = library.AAudioStream_waitForStateChange(handle, state, value, STATE_TIMEOUT_NS)
		state = library.AAudioStream_getState(handle)

		if result < 0 then
			return false
		end
	end

	return state == target
end

--- Frames the device can take right now. A stream that has not started yet can take
--- its whole buffer, which is what lets the first write fill it before playback
--- begins rather than starting on an empty device.
function Stream:avail()
	local read = tonumber(self.library.AAudioStream_getFramesRead(self.handle)) or 0
	local inFlight = self.written - (read - self.readBase)

	if inFlight < 0 then
		inFlight = 0
	end

	local free = self.capacity - inFlight

	return free > 0 and free or 0
end

---@param samples ffi.cdata*
---@param frames number
function Stream:write(samples, frames)
	if frames > self.capacity then
		frames = self.capacity
	end

	if frames <= 0 then
		return 0
	end

	local written = self.library.AAudioStream_write(self.handle, samples, frames, 0)

	if written < 0 then
		-- A stream that was stopped from underneath the player, by an underrun or a
		-- device change, must not end playback: put it back in a writable state and
		-- try the same frames again.
		local state = self.library.AAudioStream_getState(self.handle)
		if state ~= STATE_STARTED and state ~= STATE_STARTING and state ~= STATE_PAUSED then
			self.library.AAudioStream_requestStart(self.handle)
			self.isStarted = true
			written = self.library.AAudioStream_write(self.handle, samples, frames, 0)
		end

		if written < 0 then
			return 0
		end
	end

	self.written = self.written + written

	-- Output streams must have data queued before they start, or they underflow.
	-- Starting on the first successful write is what fills that buffer first.
	if not self.isStarted and not self.isPaused then
		if self.library.AAudioStream_requestStart(self.handle) >= 0 then
			self.isStarted = true
		end
	end

	return written
end

--- Frames written but not heard yet, which is the playback position's clock.
function Stream:delay()
	if self.handle == nil then
		return 0
	end

	local read = tonumber(self.library.AAudioStream_getFramesRead(self.handle)) or 0
	local inFlight = self.written - (read - self.readBase)

	return inFlight > 0 and inFlight or 0
end

--- Plays out what the device holds and then leaves it idle. This is what keeps the
--- tail of a short track from being dropped when nothing follows it.
function Stream:drain()
	local waited = 0

	while self:delay() > 0 and waited < 1000 do
		ffi.C.usleep(5000)
		waited = waited + 5
	end
end

---@param isPaused boolean
function Stream:setPaused(isPaused)
	self.isPaused = isPaused

	if isPaused then
		if self.isStarted then
			self.isStarted = false
			self.library.AAudioStream_requestPause(self.handle)
			waitForState(self, STATE_PAUSED)
		end

		return
	end

	-- A stream that was paused before it ever played starts on its first write.
	if not self.isStarted and self.written > 0 then
		if self.library.AAudioStream_requestStart(self.handle) >= 0 then
			self.isStarted = true
		end
	end
end

--- Throws away what the device still holds, which is what a seek needs. AAudio only
--- flushes a paused stream, so a running one is paused first and resumed afterwards.
function Stream:flush()
	if self.handle == nil then
		return
	end

	local wasStarted = self.isStarted
	self.isStarted = false

	if wasStarted then
		self.library.AAudioStream_requestPause(self.handle)
		waitForState(self, STATE_PAUSED)
	end

	self.library.AAudioStream_requestFlush(self.handle)
	waitForState(self, STATE_FLUSHED)

	-- The frame counters are not reset by a flush: they may advance past the dropped
	-- frames. Taking the read counter after the flush makes what is left the new zero.
	self.readBase = tonumber(self.library.AAudioStream_getFramesRead(self.handle)) or 0
	self.written = 0

	if wasStarted and not self.isPaused then
		if self.library.AAudioStream_requestStart(self.handle) >= 0 then
			self.isStarted = true
		end
	end
end

function Stream:close()
	if self.handle ~= nil then
		self.library.AAudioStream_close(self.handle)
		self.handle = nil
	end
end

---@param sampleRate number
---@param channels number
---@param device string? # An AAudio device id as text, or the default output
---@return treble.raw.aaudio.Stream? stream
---@return string? err
function lib.open(sampleRate, channels, device)
	local library = aaudio
	if library == nil then
		return nil, "AAudio is not available on this device (Android 8.0 or newer is required)"
	end

	local builders = BuilderPointer()
	local result = library.AAudio_createStreamBuilder(builders)
	if result < 0 then
		return nil, "Failed to create the AAudio stream builder: " .. errorText(result)
	end

	local builder = builders[0]

	library.AAudioStreamBuilder_setDirection(builder, DIRECTION_OUTPUT)
	library.AAudioStreamBuilder_setSharingMode(builder, SHARING_MODE_SHARED)
	library.AAudioStreamBuilder_setFormat(builder, FORMAT_PCM_I16)
	library.AAudioStreamBuilder_setChannelCount(builder, channels)
	library.AAudioStreamBuilder_setSampleRate(builder, sampleRate)
	library.AAudioStreamBuilder_setPerformanceMode(builder, PERFORMANCE_MODE_POWER_SAVING)

	local capacity = math.max(256, math.floor(sampleRate * DEVICE_LATENCY_SECONDS))
	library.AAudioStreamBuilder_setBufferCapacityInFrames(builder, capacity)

	local deviceId = tonumber(device)
	if deviceId ~= nil then
		library.AAudioStreamBuilder_setDeviceId(builder, deviceId)
	end

	local streams = StreamPointer()
	result = library.AAudioStreamBuilder_openStream(builder, streams)
	library.AAudioStreamBuilder_delete(builder)

	if result < 0 then
		return nil, "Failed to open the AAudio stream: " .. errorText(result)
	end

	local handle = streams[0]

	-- A device may round the buffer to its own burst size; use what was allocated.
	local actualCapacity = library.AAudioStream_getBufferCapacityInFrames(handle)
	if actualCapacity > 0 then
		capacity = actualCapacity
	end
	-- The capacity is only what the buffer may grow to; the part that is used starts out at a few
	-- bursts, which a writer has to top up every few milliseconds. Using all of it lets a writer
	-- sleep for a good part of DEVICE_LATENCY_SECONDS between writes, which is what a phone
	-- playing in the background wants.
	library.AAudioStream_setBufferSizeInFrames(handle, capacity)

	---@type treble.raw.aaudio.Stream
	local stream = setmetatable({
		handle = handle,
		library = library,
		sampleRate = sampleRate,
		channels = channels,
		capacity = capacity,
		written = 0,
		readBase = tonumber(library.AAudioStream_getFramesRead(handle)) or 0,
		isStarted = false,
		isPaused = false,
	}, Stream)

	return stream
end

return lib
