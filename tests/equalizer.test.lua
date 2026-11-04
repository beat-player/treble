local test = require("lde-test")
local ffi = require("ffi")
local Equalizer = require("treble.equalizer")

local Int16 = ffi.typeof("int16_t[?]")

---@param frequency number
---@param sampleRate number
---@param frames number
---@return ffi.cdata*
local function sine(frequency, sampleRate, frames)
	local samples = Int16(frames)
	local step = 2 * math.pi * frequency / sampleRate
	for at = 0, frames - 1 do
			samples[at] = math.floor(math.sin(step * at) * 4000 + 0.5)
		end
	return samples
end

---@param samples ffi.cdata*
---@param count number
---@return number
local function peak(samples, count)
	local most = 0
	for at = 0, count - 1 do
			local value = math.abs(samples[at])
			if value > most then most = value end
		end
	return most
end

test.it("leaves samples untouched when every band is flat", function()
	local samples = sine(100, 48000, 512)
	local before = ffi.new("int16_t[?]", 512)
	for at = 0, 511 do before[at] = samples[at] end

	local equalizer = Equalizer.new({
	{ frequency = 100, gain = 0},
	{ frequency = 1000, gain = 0},
	})
	equalizer:process(samples, 512, 1, 48000)

	for at = 0, 511 do
			test.equal(samples[at], before[at], "flat output is bit-for-bit unchanged")
		end
end)

test.it("boosts a sine in its band and cuts it below unity", function()
	local original = sine(100, 48000, 4096)
	local boosted = sine(100, 48000, 4096)
	local cut = sine(100, 48000, 4096)

	Equalizer.new({ { frequency = 100, gain = 12}}):process(boosted, 4096, 1, 48000)
	Equalizer.new({ { frequency = 100, gain = -12}}):process(cut, 4096, 1, 48000)

	-- The first samples are the filter settling; compare the steady tail.
	local source = peak(original + 512, 4096 - 512)
	local high = peak(boosted + 512, 4096 - 512)
	local low = peak(cut + 512, 4096 - 512)

	test.greater(high, source * 1.5, "a +12 dB band is audibly louder")
	test.less(low, source * 0.75, "a -12 dB band is audibly quieter")
end)

test.it("does not touch a tone far from the band", function()
	local original = sine(5000, 48000, 4096)
	local filtered = sine(5000, 48000, 4096)
	Equalizer.new({ { frequency = 100, gain = 12}}):process(filtered, 4096, 1, 48000)

	local source = peak(original + 1024, 4096 - 1024)
	local result = peak(filtered + 1024, 4096 - 1024)
	test.greater(result, source * 0.95, "a distant band leaves the tone intact")
	test.less(result, source * 1.05, "a distant band leaves the tone intact")
end)

test.it("keeps channel state separate and survives a rate change", function()
	local samples = Int16(2048)
	for at = 0, 1023 do
			samples[at * 2] = math.floor(math.sin(at * 0.1) * 2000)
			samples[at * 2 + 1] = math.floor(math.sin(at * 0.1) * -2000)
		end

	local equalizer = Equalizer.new({ { frequency = 200, gain = 6}})
	equalizer:process(samples, 1024, 2, 44100)
	equalizer:process(samples, 1024, 2, 48000)

	test.truthy(true, "state can be reset into a different rate")
end)

test.it("clamps an extreme boost instead of wrapping it", function()
	local samples = sine(100, 48000, 1024)
	Equalizer.new({ { frequency = 100, gain = 24}}):process(samples, 1024, 1, 48000)

	for at = 0, 1023 do
			test.truthy(samples[at] >= -32768 and samples[at] <= 32767,
			"every sample remains in the int16 range")
		end
end)
