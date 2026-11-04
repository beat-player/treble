-- Exercises the real backend. The ALSA null device takes writes and throws them
-- away, which is enough to drive the platform code on a machine with no sound
-- card, so CI can cover it.
local test = require("lde-test")
local ffi = require("ffi")
local buffer = require("string.buffer")
local fixture = require("tests.fixtures.wav")
local Player = require("treble.player")
local Wav = require("treble.formats.wav")

local Int16 = ffi.typeof("int16_t[1]")
-- A machine with no ALSA at all, such as Android, or one without a null device,
-- cannot run the tests that drive a real stream.
local canUseDevice = (function()
	if jit.os ~= "Linux" then
		return false
	end

	local loaded, output = pcall(require, "treble.output")
	if not loaded then
		return false
	end

	local stream = output.open(44100, 1, "null")
	if stream == nil then
		return false
	end

	stream:close()

	return true
end)()

-- Nor can Windows without a render endpoint, which a build machine usually has
-- none of. The reason is printed so a log says what the machine reported.
local canUseEndpoint = (function()
	if jit.os ~= "Windows" then
		return false
	end

	local loaded, output = pcall(require, "treble.output")
	if not loaded then
		return false
	end

	local stream, err = output.open(44100, 1)
	if stream == nil then
		print("skipping the backend tests: " .. tostring(err))
		return false
	end

	stream:close()

	return true
end)()

local held = {}

---@param frames number
---@return treble.Source
local function ramp(frames)
	local parts = {}
	for i = 0, frames - 1 do
		parts[#parts + 1] = ffi.string(Int16(i), 2)
	end

	local content = buffer.new()
	content:put(fixture.build({ frames = frames, sampleBytes = table.concat(parts) }))
	held[#held + 1] = content

	return assert(Wav.fromMemory(ffi.cast("const char*", content:ref()), #content))
end

test.skipIf(not canUseDevice)("plays a track through the real backend", function()
	local player = Player.new({ device = "null" })

	local errors = {}
	player.onError = function(err)
		errors[#errors + 1] = err
	end

	local ended = 0
	player.onTrackEnd = function()
		ended = ended + 1
	end

	player:enqueue(ramp(4000))
	player:play()

	for _ = 1, 60 do
		player:update()
	end

	test.equal(#errors, 0, "the device accepted the track")
	test.truthy(ended > 0, "the track played out")
	test.equal(player:isFinished(), true, "and the player let the device go")
	player:stop()
end)

test.skipIf(not canUseEndpoint)("plays a track through the real backend", function()
	local player = Player.new()

	local errors = {}
	player.onError = function(err)
		errors[#errors + 1] = err
	end

	local ended = 0
	player.onTrackEnd = function()
		ended = ended + 1
	end

	player:enqueue(ramp(4000))
	player:play()

	-- The endpoint renders on its own clock, so this waits for it rather than
	-- counting frames.
	local deadline = os.time() + 5
	while os.time() < deadline do
		player:update()

		if player:isFinished() then
			break
		end
	end

	test.equal(#errors, 0, "the default endpoint accepted the track")
	test.truthy(ended > 0, "the track played out")
	player:stop()
end)

test.skipIf(jit.os ~= "OSX")("opens the output unit and takes a whole track", function()
	-- A virtual machine has no audio hardware, so this drives the unit that renders
	-- without a device: opening it, the shim's ring buffer and the whole write path
	-- are covered. Rendering in real time is the same callback with a device behind
	-- it, which only a machine with hardware can exercise.
	local player = Player.new({ device = "none" })

	local errors = {}
	player.onError = function(err)
		errors[#errors + 1] = err
	end

	player:enqueue(ramp(4000))
	player:play()

	for _ = 1, 60 do
		player:update()
	end

	test.equal(#errors, 0, "the output unit opened")
	test.falsy(player:isFeeding(), "the whole track was accepted")
	player:stop()
end)

test.skipIf(not canUseDevice)("seeks and resumes through the real backend", function()
	local player = Player.new({ device = "null" })

	local errors = {}
	player.onError = function(err)
		errors[#errors + 1] = err
	end

	player:enqueue(ramp(8000))
	player:play()
	player:update()

	test.truthy(player:seek(0.5), "seek reports success")
	test.equal(math.floor(player:position() * 1000), 500)

	player:update()
	test.equal(#errors, 0)
	player:stop()
end)
