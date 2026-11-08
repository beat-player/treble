local test = require("lde-test")
local ffi = require("ffi")
local buffer = require("string.buffer")
local fixture = require("tests.fixtures.wav")
local FakeStream = require("tests.fixtures.stream")
local Player = require("treble.player")
local Wav = require("treble.formats.wav")

local Int16 = ffi.typeof("int16_t[1]")

-- Sources read from caller memory, so the buffers have to outlive the tests.
local held = {}

---@param content string
---@return treble.Source
local function open(content)
	local content_ = buffer.new()
	content_:put(content)
	held[#held + 1] = content_

	return assert(Wav.fromMemory(ffi.cast("const char*", content_:ref()), #content_))
end

---@alias tests.SampleFunc fun(index: number): number

--- A ramp makes it possible to say which frame any written sample came from.
---@param opts { frames: number, channels: number?, sampleRate: number?, value: tests.SampleFunc? }
---@return treble.Source
local function ramp(opts)
	local channels = opts.channels or 1
	local parts = {}

	for i = 0, opts.frames * channels - 1 do
			local sample = opts.value ~= nil and opts.value(i) or i
			parts[#parts + 1] = ffi.string(Int16(sample), 2)
		end

	return open(fixture.build({
	sampleRate = opts.sampleRate or 8000,
	channels = channels,
	frames = opts.frames,
	sampleBytes = table.concat(parts),
	}))
end

---@alias tests.StreamFactory fun(sampleRate: number, channels: number): treble.OutputStream

---@param opts tests.FakeStream.Opts?
---@return tests.StreamFactory factory
---@return tests.FakeStream[] created
local function factory(opts)
	local created = {}

	return function(sampleRate, channels)
		local stream = FakeStream.new(sampleRate, channels, opts)
		created[#created + 1] = stream
		return stream
	end, created
end

--- Runs playback frames, letting the fake devices hear what they were handed
--- between them. A stream is opened lazily, so this takes the list the factory
--- filled rather than one stream. It runs a fixed number of frames rather than
--- stopping when a track ends, since a queue moves on between tracks.
---@param player treble.Player
---@param created tests.FakeStream[]
---@param steps number?
local function run(player, created, steps)
	for _ = 1, (steps or 60) do
			player:update()

			for _, stream in ipairs(created) do
					stream:play(stream.queued)
				end
		end
end

test.it("writes a whole track to the device", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 2000}))
	player:play()
	run(player, created)

	test.equal(created[1].writtenFrames, 2000)
	test.equal(created[1].queued, 0)
end)

test.it("hands the frames over unchanged at full volume", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 100}))
	player:play()
	run(player, created)

	test.equal(created[1].written[0], 0)
	test.equal(created[1].written[50], 50)
	test.equal(created[1].written[99], 99)
end)

test.it("scales frames by the volume", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:setVolume(0.5)
	player:enqueue(ramp({ frames = 100}))
	player:play()
	run(player, created)

	test.equal(created[1].written[0], 0)
	test.equal(created[1].written[50], 25)
	test.equal(created[1].written[99], 49)
end)

test.it("clamps a boosted frame instead of wrapping it", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:setVolume(1.5)
	player:enqueue(ramp({
	frames = 4,
	value = function()
		return 32000
	end,
	}))
	player:play()
	run(player, created)

	test.equal(created[1].written[0], 32767, "a boosted sample stops at full scale")
end)

test.it("caps the volume at 1.5", function()
	local player = Player.new({ stream = factory()})
	player:setVolume(4)

	test.equal(player.volume, 1.5)
end)

test.it("plays the queue in order and reports each track", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	local ended = 0
	player.onTrackEnd = function()
		ended = ended + 1
	end

	player:enqueue(ramp({ frames = 500}))
	player:enqueue(ramp({ frames = 300}))
	player:play()
	run(player, created)

	test.equal(ended, 2, "each track reported its end")
	test.equal(created[1].written[0], 0, "the first track was written from its start")
	test.equal(created[1].writtenFrames, 800)
end)

test.it("plays a track that cannot say how long it is to the end of its data", function()
	-- Less staged, and less held by the device, than the first track is long: its data has not run
	-- out while it plays, which is a real track's case.
	local create, created = factory({ capacity = 1000, total = 10000})
	local player = Player.new({ stream = create, stagingSeconds = 0.05})

	local ended = 0
	player.onTrackEnd = function()
		ended = ended + 1
	end

	-- An MP3 with no Xing or Info header: its frames are all there, but the decoder will not walk
	-- the file to count them, so it says nought until it runs out of them.
	local function unmeasured(source)
		return {
			channels = source.channels,
			sampleRate = source.sampleRate,
			frameCount = 0,
			read = function(_, out, frames) return source:read(out, frames) end,
			seek = function(_, frame) return source:seek(frame) end,
			close = function() source:close() end,
		}
	end
	local first, second = unmeasured(ramp({ frames = 3000})), unmeasured(ramp({ frames = 1000}))
	player:enqueue(first)
	player:enqueue(second)
	player:play()

	for _ = 1, 4 do
			player:update()
		end
	test.equal(ended, 0, "a track is not over before any of it was heard")

	created[1]:play(600)
	player:update()
	test.equal(ended, 0, "nor part way through")
	test.equal(player:position(), 600 / 8000, "and its position runs from the frames heard")

	run(player, created, 200)
	test.equal(created[1].writtenFrames, 4000, "both tracks played to the end of their data")
	test.equal(ended, 2, "and each reported its end once")
end)

test.it("hands the next track to the device while the first is unplayed", function()
	local create, created = factory({ capacity = 8000, total = 40000})
	local player = Player.new({ stream = create})

	local ended = 0
	player.onTrackEnd = function()
		ended = ended + 1
	end

	player:enqueue(ramp({ frames = 3000}))
	player:enqueue(ramp({
	frames = 3000,
	value = function(index)
		return index + 10000
	end,
	}))
	player:play()

	-- fill the device without letting it play anything yet
	for _ = 1, 8 do
			player:update()
		end

	local stream = created[1]
	test.equal(stream.queued, stream.writtenFrames, "nothing has been heard")
	test.equal(stream.writtenFrames, 6000, "both tracks are on the device")
	test.equal(stream.written[0], 0, "the first track comes first")
	test.equal(stream.written[3000], 10000, "the second track follows it with nothing in between")
	test.equal(ended, 0, "no track has ended yet")
end)

test.it("skips to the next queued track", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 4000}))
	player:enqueue(ramp({
	frames = 1000,
	value = function(index)
		return index + 10000
	end,
	}))
	player:play()
	player:update()

	local stream = created[1]
	test.greater(stream.writtenFrames, 0, "the first track reached the device")

	test.truthy(player:next(), "there is somewhere to skip to")
	test.equal(stream.flushes, 1, "the device was emptied of the skipped track")
	test.equal(player:position(), 0, "the next track starts at its beginning")

	local before = stream.writtenFrames
	player:update()
	test.equal(stream.written[before], 10000, "and it plays from its own first frame")
end)

test.it("does not skip past the end of the queue", function()
	local create = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 200}))
	player:play()
	player:update()

	test.falsy(player:next(), "there is nothing queued after this track")
end)

test.it("reports the position from the device", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 8000}))
	player:play()
	player:update()

	local stream = created[1]
	test.greater(stream.writtenFrames, 0, "the device was fed")
	test.equal(player:position(), 0, "nothing has been heard yet")

	stream:play(stream.writtenFrames / 2)
	test.equal(player:position(), stream.writtenFrames / 2 / 8000, "half of what was written has played")
end)

test.it("seeks, drops what the device held, and plays on from there", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 8000}))
	player:play()
	player:update()

	local stream = created[1]
	local before = stream.writtenFrames

	test.truthy(player:seek(0.5), "seek reports success")
	test.equal(stream.flushes, 1, "a seek throws away the audio already queued")
	test.equal(player:position(), 0.5)

	player:update()
	test.equal(stream.written[before], 4000, "the write after the seek comes from the target frame")
end)

test.it("seeks to absolute seconds after an earlier seek", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 8000}))
	player:play()
	player:update()

	local stream = created[1]
	test.truthy(player:seek(0.5), "the first seek reports success")
	test.truthy(player:seek(0.25), "the second seek reports success")
	test.equal(player:position(), 0.25, "the second seek is measured from the start of the track")

	local before = stream.writtenFrames
	player:update()
	test.equal(stream.written[before], 2000, "and reads from that absolute frame")
end)

test.it("keeps a seek made before the first update", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 8000}))
	player:play()
	test.truthy(player:seek(0.5), "a seek before adoption is kept")
	player:update()

	local stream = created[1]
	test.equal(stream.written[0], 4000, "the first write starts at the seeked frame instead of nought")
end)

test.it("reports the duration of the current track", function()
	local player = Player.new({ stream = factory()})
	player:enqueue(ramp({ frames = 22050, sampleRate = 44100}))
	player:update()

	test.equal(player:duration(), 0.5)
end)

test.it("stops writing while paused and picks up again", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 8000}))
	player:play()
	player:update()

	local stream = created[1]
	local writtenBefore = stream.writtenFrames

	player:pause()
	player:update()

	test.equal(stream.isPaused, true)
	test.equal(stream.writtenFrames, writtenBefore, "paused playback writes nothing")

	player:play()
	test.equal(stream.isPaused, false)

	stream:play(stream.queued)
	player:update()
	test.greater(stream.writtenFrames, writtenBefore, "resuming writes again")
end)

test.it("releases the device once the queue is empty and the device is quiet", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 1000}))
	player:play()
	run(player, created)
	player:update()

	test.equal(created[1].isClosed, true)
end)

test.it("opens a stream per sample rate", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 100}))
	player:enqueue(ramp({ frames = 100, sampleRate = 22050}))
	player:play()
	run(player, created)

	test.equal(#created, 2, "the second track needed its own stream")
	test.equal(created[2].sampleRate, 22050)
	test.equal(created[1].isClosed, true, "the first stream was released")
end)

test.it("stops, rewinds, and closes the device", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 8000}))
	player:play()
	player:update()
	player:seek(0.25)
	player:stop()

	test.equal(created[1].isClosed, true)
	test.equal(player:position(), 0)
	test.equal(player:isPlaying(), false)

	player:play()
	player:update()
	test.greater(#created, 0, "playback can start again")
end)

test.it("plays a whole track through pump without a frame loop", function()
	local create, created = factory({ isBlocking = true, total = 20000})
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 8000}))
	player:play()
	player:pump()

	test.equal(created[1].writtenFrames, 8000, "everything is on the device")
	test.equal(player:isFeeding(), false)
end)

test.it("pumps the whole queue and reports tracks as they are heard", function()
	local create, created = factory({ isBlocking = true, total = 20000})
	local player = Player.new({ stream = create})

	local ended = 0
	player.onTrackEnd = function()
		ended = ended + 1
	end

	player:enqueue(ramp({ frames = 1000}))
	player:enqueue(ramp({ frames = 500}))
	player:play()
	player:pump()

	test.equal(created[1].writtenFrames, 1500, "everything is on the device")
	test.equal(ended, 0, "nothing has been heard yet")

	-- let the device play it, and the ends follow the audio rather than the pump
	player.onTrackEnd = function()
		ended = ended + 1
	end
	run(player, created, 10)

	test.equal(ended, 2, "both tracks were reported once they had played")
end)

test.it("reports when it has nothing left and the device is quiet", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	player:enqueue(ramp({ frames = 500}))
	player:play()
	test.falsy(player:isFinished(), "a queued track is not finished")

	run(player, created)
	player:update()

	test.truthy(player:isFinished(), "the queue is empty and the device is silent")
end)

test.it("reports a failing source and plays the next track", function()
	local create, created = factory()
	local player = Player.new({ stream = create})

	local broken = {
	channels = 1,
	sampleRate = 8000,
	frameCount = 1000,
	read = function()
		return nil, "the file went away"
	end,
	seek = function()
		return true
	end,
	close = function()
	end,
	}

	local errors = {}
	player.onError = function(err)
		errors[#errors + 1] = err
	end

	local ended = 0
	player.onTrackEnd = function()
		ended = ended + 1
	end

	player:enqueue(broken)
	player:enqueue(ramp({ frames = 500}))
	player:play()
	run(player, created)

	test.equal(#errors, 1, "the failure was reported once")
	test.includes(errors[1], "the file went away")
	test.equal(created[1].writtenFrames, 500, "the next track still played")
	test.equal(ended, 2, "the failed track and the good one both ended")
end)

test.it("reports a device it cannot open without raising when onError is set", function()
	local player = Player.new({
	stream = function()
		return nil, "WASAPI playback is not implemented"
	end,
	})

	local errors = {}
	player.onError = function(err)
		errors[#errors + 1] = err
	end

	player:enqueue(ramp({ frames = 100}))
	player:play()

	local ok = pcall(function()
		player:update()
	end)

	test.truthy(ok, "onError takes the place of raising")
	test.equal(#errors, 1)
	test.includes(errors[1], "WASAPI playback is not implemented")
end)

test.it("reports a device it cannot open", function()
	local player = Player.new({
	stream = function()
		return nil, "WASAPI playback is not implemented"
	end,
	})
	player:enqueue(ramp({ frames = 100}))
	player:play()

	local ok, err = pcall(function()
		player:update()
	end)

	test.falsy(ok)
	test.includes(tostring(err), "WASAPI playback is not implemented")
end)
