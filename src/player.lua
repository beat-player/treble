-- The player: one output stream, a queue of sources, and a staging buffer between
-- them.
--
-- What is being decoded and what the device is playing are two different tracks
-- once a track has been handed over, which is what keeps the stream from running
-- dry between tracks. A track ends when the device has played past it, not when its
-- decoder runs out, so the position and onTrackEnd follow what is audible.
local ffi = require("ffi")
local Audio = require("treble.audio")
local Equalizer = require("treble.equalizer")
local output = require("treble.output")

local SampleBuffer = ffi.typeof("int16_t[?]")

local MAX_VOLUME = 1.5
local MAX_SAMPLE = 32767
local MIN_SAMPLE = -32768

-- A quarter second of staging keeps the device fed between frames without holding
-- so much audio that a seek or a volume change feels late.
local STAGING_SECONDS = 0.25

---@alias treble.Player.StreamFactory fun(sampleRate: number, channels: number, device: string?): treble.OutputStream?, string?

---@class treble.Player.Track
---@field source treble.Source
---@field isOwned boolean
---@field startFrame number # Where the track begins in the device timeline
---@field frames number # How many frames it plays, 0 until a source of unknown length ends
---@field sourceStart number # The source frame the start of the timeline maps to
---@field isDone boolean # The decoder has nothing left to give for this track

---@class treble.Player.QueueItem
---@field item string|treble.Source
---@field isOwned boolean

---@class treble.Player
---@field onTrackEnd fun()? # Called when a track has played out
---@field onError fun(err: string)? # Called when a source or the device fails
---@field onSamples fun(samples: ffi.cdata*, frames: number, channels: number)? # Decoded PCM, after equalizer and volume
---@field volume number
---@field private equalizer treble.Equalizer?
---@field private queue treble.Player.QueueItem[]
---@field private playing treble.Player.Track? # The track the device is hearing
---@field private decoding treble.Player.Track? # The track being decoded ahead of it
---@field private stream treble.OutputStream?
---@field private streamFactory treble.Player.StreamFactory
---@field private device string?
---@field private staging ffi.cdata*
---@field private stagingCapacity number
---@field private stagingSeconds number # How much decoded audio is held between frames
---@field private stagedOffset number
---@field private stagedFrames number
---@field private framesWritten number # Cumulative, in the device timeline
---@field private isPaused boolean
---@field private isStopped boolean
---@field private pendingSeek number? # A seek asked for before the next track is adopted
local Player = {}
Player.__index = Player

---@param opts { stream: treble.Player.StreamFactory?, device: string?, stagingSeconds: number? }? # stream defaults to this platform's backend
---@return treble.Player
function Player.new(opts)
	opts = opts or {}

	---@type treble.Player
	local player = setmetatable({
	onTrackEnd = nil,
	onError = nil,
	volume = 1,
	queue = {},
	playing = nil,
	decoding = nil,
	stream = nil,
	streamFactory = opts.stream or output.open,
	device = opts.device,
	staging = nil,
	stagingCapacity = 0,
	stagingSeconds = opts.stagingSeconds or STAGING_SECONDS,
	stagedOffset = 0,
	stagedFrames = 0,
	framesWritten = 0,
	isPaused = false,
	isStopped = false,
	pendingSeek = nil,
	}, Player)

	return player
end

--- Appends a track. A path is opened when its turn comes, so a long queue does not
--- hold every file open.
---@param item string|treble.Source
function Player:enqueue(item)
	self.queue[#self.queue + 1] = { item = item, isOwned = false}

	return self
end

--- Puts a track into the queue in front of whatever is left, keeping the fact that
--- the player opened it.
---@param item treble.Player.QueueItem
function Player:requeue(item)
	table.insert(self.queue, 1, item)

	return self
end

--- The frame the device is playing now, in the timeline the tracks share.
function Player:playedFrames()
	local delay = self.stream ~= nil and self.stream:delay() or 0

	return self.framesWritten - delay
end

--- Where a seek lands in a source, and the frames left after it. A source that cannot say how long
--- it is has no end to stop the seek at, and nothing left to count: its length stays unknown until
--- its data runs out.
---@param source treble.Source
---@param seconds number
---@return number frame
---@return number frames
local function seekTarget(source, seconds)
	local frame = math.max(0, math.floor(seconds * source.sampleRate))
	if source.frameCount == 0 then
		return frame, 0
	end

	frame = math.min(frame, source.frameCount)
	return frame, source.frameCount - frame
end

--- Takes the next queued track and places it after everything already on its way to
--- the device, which is the timeline position of the frames still staged.
---@return treble.Player.Track? track
function Player:adopt()
	local queued = table.remove(self.queue, 1)
	if queued == nil then
		return nil
	end

	local source = queued.item
	local isOwned = queued.isOwned

	if type(source) == "string" then
		source = assert(Audio.fromPath(source))
		isOwned = true
	elseif not isOwned then
		source:seek(0)
	end
	---@cast source treble.Source

	---@type treble.Player.Track
	local track = {
	source = source,
	isOwned = isOwned,
	startFrame = self.framesWritten + self.stagedFrames,
	frames = source.frameCount,
	sourceStart = 0,
	isDone = false,
	}

	-- A seek made while no track was adopted is held until this one is: it is what lets a queue
	-- order change carry on at the same point instead of starting the source at nought.
	local pendingSeek = self.pendingSeek
	self.pendingSeek = nil
	if pendingSeek ~= nil then
		local frame, frames = seekTarget(source, pendingSeek)
		if source:seek(frame) then
			track.sourceStart = frame
			track.frames = frames
		end
	end

	-- The track that follows the one the device is hearing is the one to decode.
	if self.playing == nil then
		self.playing = track
	else
		self.decoding = track
	end

	if self.staging == nil or self.stagingCapacity == 0 then
		self.stagingCapacity = math.max(1, math.floor(source.sampleRate * self.stagingSeconds))
		self.staging = SampleBuffer(self.stagingCapacity * source.channels)
	end

	return track
end

--- Whether a track's end is known: a source that cannot say how long it is reports nought frames,
--- and says it by ending -- until its data runs out, nought is no length at all.
---@param track treble.Player.Track
local function lengthKnown(track)
	return track.isDone or track.frames > 0
end

--- Fires onTrackEnd for each track the device has played past and lets it go.
function Player:releaseHeard()
	local played = self:playedFrames()
	local track = self.playing

	while track ~= nil and lengthKnown(track) and played >= track.startFrame + track.frames do
		if track.isOwned then
			track.source:close()
		end

		self.playing = self.decoding
		self.decoding = nil

		if self.onTrackEnd ~= nil then
			self.onTrackEnd()
		end

		track = self.playing
	end
end

--- Hands a failure to onError, or raises when nothing is listening.
---@param err string
function Player:reportError(err)
	if self.onError ~= nil then
		self.onError(err)
		return
	end

	error(err)
end

--- Opens the device for a track, or reopens it when the track needs a different
--- rate or channel count. Returns false when it could not be opened, after
--- reporting why.
---@param source treble.Source
---@return boolean ok
function Player:openStream(source)
	if self.stream ~= nil then
		self.stream:close()
	end

	local stream, err = self.streamFactory(source.sampleRate, source.channels, self.device)
	if stream == nil then
		self:reportError(err or "Failed to open the audio output")
		self.isStopped = true

		return false
	end

	self.stream = stream

	return true
end

--- True when the open stream cannot play the given track.
---@param source treble.Source
function Player:needsNewStream(source)
	return self.stream ~= nil
	and (self.stream.sampleRate ~= source.sampleRate or self.stream.channels ~= source.channels)
end

---@param samples ffi.cdata*
---@param count number # Samples, not frames
function Player:applyVolume(samples, count)
	local gain = self.volume
	if gain == 1 then
		return
	end

	for i = 0, count - 1 do
			-- Scaling past the sample range wraps the sign, which sounds like noise.
			samples[i] = math.max(MIN_SAMPLE, math.min(MAX_SAMPLE, math.floor(samples[i] * gain)))
		end
end

--- Decodes ahead into the staging buffer. A source may give back fewer frames than
--- asked for, and returns 0 once it is spent.
function Player:fill()
	local track = self.decoding or self.playing
	if track == nil or track.isDone then
		return
	end

	local channels = track.source.channels

	while self.stagedFrames < self.stagingCapacity do
		if self.stagedFrames == 0 then
			self.stagedOffset = 0
		end

		local room = self.stagingCapacity - (self.stagedOffset + self.stagedFrames)
		if room == 0 then
			return
		end

		local samples = self.staging + (self.stagedOffset + self.stagedFrames) * channels
		local frames, err = track.source:read(samples, room)
		if frames == nil then
			-- The data behind this track went away. Report it and move on to the
			-- next one rather than treating it as a quiet end of track.
			self:reportError(err or "Failed to read audio data")
			track.isDone = true

			-- Only what was handed over will ever play, so the boundary has to move
			-- to where this track actually stops.
			track.frames = self.framesWritten + self.stagedFrames - track.startFrame

			return
		end

		if frames == 0 then
			track.isDone = true

			-- A source that cannot say how long it is has now said it by ending.
			if track.frames == 0 then
				track.frames = self.framesWritten + self.stagedFrames - track.startFrame
			end

			return
		end

		if self.equalizer ~= nil then
			self.equalizer:process(samples, frames, channels, track.source.sampleRate)
		end
		self:applyVolume(samples, frames * channels)
		if self.onSamples ~= nil then self.onSamples(samples, frames, channels) end
		self.stagedFrames = self.stagedFrames + frames
	end
end

---@param isBlocking boolean
function Player:writeStaged(isBlocking)
	local stream = self.stream
	if stream == nil then return end
	local channels = self.playing ~= nil and self.playing.source.channels or 1
	if self.decoding ~= nil then
		channels = self.decoding.source.channels
	end

	local frames = self.stagedFrames
	if not isBlocking then
		frames = math.min(stream:avail(), frames)
	end

	if frames == 0 then
		return
	end

	local written = stream:write(self.staging + self.stagedOffset * channels, frames)

	self.stagedOffset = self.stagedOffset + written
	self.stagedFrames = self.stagedFrames - written
	self.framesWritten = self.framesWritten + written
end

--- True while there is audio left to hand to the device.
function Player:isFeeding()
	local active = self.decoding or self.playing

	return self.stagedFrames > 0 or (#self.queue > 0 and not self.isStopped and not self.isPaused)
	or (active ~= nil and not active.isDone)
end

--- One step of playback: pull, then push. Call it once per frame.
function Player:update()
	self:releaseHeard()

	if self.isStopped or self.isPaused then
		return
	end

	local active = self.decoding or self.playing
	if active == nil or active.isDone then
		active = self:adopt() or self.decoding or self.playing
	end

	if self.stream ~= nil and active ~= nil and self:needsNewStream(active.source) then
		-- A track at another rate needs its own stream, which can only be opened
		-- once the device has played out what the old one holds.
		if self.stream:delay() > 0 then
			return
		end

		self.stream:close()
		self.stream = nil
	end

	if self.stream == nil then
		if active == nil then
			return
		end

		if not self:openStream(active.source) then
			return
		end
	end

	self:fill()
	self:writeStaged(false)

	-- Nothing left anywhere: play the tail out and let the device go.
	if self.playing == nil and self.decoding == nil and self.stagedFrames == 0 and #self.queue == 0 then
		self.stream:drain()

		if self.stream:delay() == 0 then
			self.stream:close()
			self.stream = nil
		end
	end
end

--- Hands the whole queue to the device, blocking while the device is full. This is
--- what makes a one shot sound need no frame loop: treble.play returns once the
--- audio is on its way, and the device plays it out on its own.
function Player:pump()
	while true do
		local active = self.decoding or self.playing

		if active == nil or active.isDone then
			if #self.queue > 0 then
				active = self:adopt()
			else
				active = nil
			end
		end

		if active == nil then
			break
		end

		if self.isStopped or self.isPaused then
			return
		end

		if self.stream ~= nil and self:needsNewStream(active.source) then
			if self.stream:delay() > 0 then
				return
			end

			self.stream:close()
			self.stream = nil
		end

		if self.stream == nil then
			if not self:openStream(active.source) then
				return
			end
		end

		self:fill()

		while self.stagedFrames > 0 do
			local before = self.stagedFrames
			self:writeStaged(true)
			if self.stagedFrames == before then
				-- The device is not taking anything, so wait for the next pump
				-- rather than spinning on it.
				return
			end
		end
	end

	if self.stream ~= nil then
		-- Everything is on the device; play the tail out rather than leaving it
		-- queued.
		self.stream:drain()
	end
end

--- Skips to the next track, dropping what is playing and everything already on
--- its way to the device. Playback continues with whatever is next in the queue.
---@return boolean skipped
function Player:next()
	local following = self.decoding

	if following == nil and #self.queue == 0 then
		-- Nothing to go to, so leave what is playing alone.
		return false
	end

	if self.stream ~= nil then
		-- Everything the device holds belongs to the track being skipped.
		self.stream:flush()
	end

	local current = self.playing
	if current ~= nil and current.isOwned then
		current.source:close()
	end

	self.framesWritten = 0
	self.stagedOffset = 0
	self.stagedFrames = 0

	if following ~= nil then
		-- The track being decoded was already on the device, so it starts over.
		following.source:seek(0)
		following.sourceStart = 0
		following.startFrame = 0
		following.frames = following.source.frameCount
		following.isDone = false

		self.playing = following
		self.decoding = nil
	else
		self.playing = nil
		self.decoding = nil
	end

	return true
end

--- Starts or resumes playback.
function Player:play()
	self.isStopped = false

	if self.isPaused then
		self.isPaused = false
		if self.stream ~= nil then
			self.stream:setPaused(false)
		end
	end

	return self
end

--- Stops the device without giving up the queue or the position.
function Player:pause()
	self.isPaused = true
	if self.stream ~= nil then
		self.stream:setPaused(true)
	end

	return self
end

--- Stops playback and releases the device, rewinding the current track.
function Player:stop()
	if self.stream ~= nil then
		self.stream:flush()
		self.stream:close()
		self.stream = nil
	end

	if self.playing ~= nil then
		-- Back to the top of the track, not to wherever a seek left it.
		self.playing.source:seek(0)
		self.playing.sourceStart = 0
		self.playing.startFrame = 0
		self.playing.frames = self.playing.source.frameCount
		self.playing.isDone = false
	end

	self.decoding = nil
	self.stagedOffset = 0
	self.stagedFrames = 0
	self.framesWritten = 0
	self.isPaused = false
	self.isStopped = true
	self.pendingSeek = nil

	return self
end

--- Drops everything and closes what the player opened.
function Player:close()
	self.pendingSeek = nil
	if self.equalizer ~= nil then self.equalizer:reset() end
	if self.stream ~= nil then
		self.stream:close()
		self.stream = nil
	end

	for _, track in ipairs({ self.playing, self.decoding}) do
			if track ~= nil and track.isOwned then
				track.source:close()
			end
		end

	for _, queued in ipairs(self.queue) do
			local item = queued.item
			if queued.isOwned and type(item) ~= "string" then
				item:close()
			end
		end

	self.queue = {}
	self.playing = nil
	self.decoding = nil
	self.stagedOffset = 0
	self.stagedFrames = 0
	self.framesWritten = 0
	self.isPaused = false
	self.isStopped = true
end

---@param seconds number
function Player:seek(seconds)
	local track = self.playing
	if track == nil then
		self.pendingSeek = seconds
		return true
	end

	local source = track.source
	-- Seconds are into the track, and the source is a decode of that whole track: an earlier
	-- seek moved the source's read head but did not move the track's zero, so adding that head
	-- here would make every seek after the first one jump by where it started.
	local frame, frames = seekTarget(source, seconds)

	if not source:seek(frame) then
		return false
	end

	if self.stream ~= nil then
		-- Throw away what the device still holds, or the old position keeps playing.
		self.stream:flush()
	end

	-- The track queued behind this one had frames on the device that the flush just
	-- dropped, so it has to start over.
	local carried = self.decoding
	if carried ~= nil then
		carried.source:seek(0)
		carried.frames = carried.source.frameCount
		carried.startFrame = source.frameCount - frame
		carried.sourceStart = 0
		carried.isDone = false
		self:requeue({ item = carried.source, isOwned = carried.isOwned})
		self.decoding = nil
	end

	track.sourceStart = frame
	track.frames = frames
	track.startFrame = 0
	-- The source reads on from the seek, so whatever it had run out of, it has data again.
	track.isDone = false

	self.framesWritten = 0
	self.stagedOffset = 0
	self.stagedFrames = 0

	return true
end

--- Seconds into the current track, taken from the device: the frames it has played
--- of the timeline this track starts at.
function Player:position()
	local track = self.playing
	if track == nil then
		return 0
	end

	local played = self:playedFrames() - track.startFrame
	local frames = math.max(0, lengthKnown(track) and math.min(played, track.frames) or played)

	return (track.sourceStart + frames) / track.source.sampleRate
end

--- Seconds long the current track is, or 0 when its format cannot say.
function Player:duration()
	local track = self.playing
	if track == nil then
		return 0
	end

	return track.source.frameCount / track.source.sampleRate
end

--- True while a track is loaded and not paused or stopped.
function Player:isPlaying()
	return self.playing ~= nil and not self.isPaused and not self.isStopped
end

--- True once there is nothing left to hear: nothing playing, nothing queued, and the
--- device silent.
function Player:isFinished()
	if self.playing ~= nil or self.decoding ~= nil or #self.queue > 0 then
		return false
	end

	local delay = self.stream ~= nil and self.stream:delay() or 0

	return delay == 0
end

--- Configures the graphic equalizer. An empty list, or every band at zero, is the
--- path the player takes when there is nothing to filter. The bands are copied so a
--- caller can change its own table without changing what is already playing.
---@param bands treble.Equalizer.Band[]?
---@return treble.Player
function Player:setEqualizer(bands)
	if bands == nil or #bands == 0 then
		self.equalizer = nil
		return self
	end

	local copy = {}
	for at = 1, #bands do
			local band = bands[at]
			copy[#copy + 1] = {
			frequency = band.frequency,
			gain = band.gain,
			q = band.q,
			}
		end

	local equalizer = Equalizer.new(copy)
	self.equalizer = equalizer:isFlat() and nil or equalizer
	return self
end

---@param volume number
function Player:setVolume(volume)
	self.volume = math.max(0, math.min(MAX_VOLUME, volume))

	return self
end

return Player
