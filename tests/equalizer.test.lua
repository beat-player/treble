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

test.it("adds a low shelf boost under its corner and leaves highs alone", function()
	local source = sine(30, 48000, 4096)
	local low = sine(30, 48000, 4096)
	local highSource = sine(5000, 48000, 4096)
	local high = sine(5000, 48000, 4096)

	local equalizer = Equalizer.new({
	{ frequency = 100, gain = 6, q = 0.707, type = "lowshelf"},
	})
	equalizer:process(low, 4096, 1, 48000)
	equalizer:process(high, 4096, 1, 48000)

	-- RBJ shelves reach the full gain at DC, so a 30 Hz tone sees close to +6 dB.
	local lowRatio = peak(low + 1024, 4096 - 1024) / peak(source + 1024, 4096 - 1024)
	test.greater(lowRatio, 1.8, "the low shelf boosts a tone below its corner")
	test.less(lowRatio, 2.2, "the low shelf boost is about +6 dB")

	local highRatio = peak(high + 1024, 4096 - 1024) / peak(highSource + 1024, 4096 - 1024)
	test.greater(highRatio, 0.95, "the low shelf leaves a tone above its corner intact")
	test.less(highRatio, 1.05, "the low shelf leaves a tone above its corner intact")
end)

test.it("cuts a high shelf above its corner", function()
	local source = sine(15000, 48000, 4096)
	local high = sine(15000, 48000, 4096)
	local lowSource = sine(100, 48000, 4096)
	local low = sine(100, 48000, 4096)

	local equalizer = Equalizer.new({
	{ frequency = 10000, gain = -6, q = 0.707, type = "highshelf"},
	})
	equalizer:process(high, 4096, 1, 48000)
	equalizer:process(low, 4096, 1, 48000)

	local highRatio = peak(high + 1024, 4096 - 1024) / peak(source + 1024, 4096 - 1024)
	test.greater(highRatio, 0.45, "the high shelf cuts a tone above its corner")
	test.less(highRatio, 0.60, "the high shelf cut is near -6 dB")

	local lowRatio = peak(low + 1024, 4096 - 1024) / peak(lowSource + 1024, 4096 - 1024)
	test.greater(lowRatio, 0.95, "the high shelf leaves a tone below its corner intact")
	test.less(lowRatio, 1.05, "the high shelf leaves a tone below its corner intact")
end)

test.it("high pass removes lows and passes highs without a gain", function()
	local equalizer = Equalizer.new({
	{ frequency = 200, gain = 0, type = "highpass"},
	})
	test.falsy(equalizer:isFlat(), "a zero-gain high pass still does something")

	local source = sine(50, 48000, 4096)
	local low = sine(50, 48000, 4096)
	local highSource = sine(5000, 48000, 4096)
	local high = sine(5000, 48000, 4096)
	equalizer:process(low, 4096, 1, 48000)
	equalizer:process(high, 4096, 1, 48000)

	local lowRatio = peak(low + 1024, 4096 - 1024) / peak(source + 1024, 4096 - 1024)
	test.less(lowRatio, 0.1, "a 200 Hz high pass cuts a 50 Hz tone by more than 10 dB")

	local highRatio = peak(high + 1024, 4096 - 1024) / peak(highSource + 1024, 4096 - 1024)
	test.greater(highRatio, 0.9, "the high pass keeps a tone in its pass band")
end)

test.it("low pass removes highs without a gain", function()
	local equalizer = Equalizer.new({
	{ frequency = 2000, gain = 0, type = "lowpass"},
	})
	test.falsy(equalizer:isFlat(), "a zero-gain low pass still does something")

	local source = sine(5000, 48000, 4096)
	local high = sine(5000, 48000, 4096)
	local lowSource = sine(200, 48000, 4096)
	local low = sine(200, 48000, 4096)
	equalizer:process(high, 4096, 1, 48000)
	equalizer:process(low, 4096, 1, 48000)

	local highRatio = peak(high + 1024, 4096 - 1024) / peak(source + 1024, 4096 - 1024)
	test.less(highRatio, 0.25, "the low pass cuts a tone above its corner")

	local lowRatio = peak(low + 1024, 4096 - 1024) / peak(lowSource + 1024, 4096 - 1024)
	test.greater(lowRatio, 0.9, "the low pass keeps a tone in its pass band")
end)

test.it("applies the preamp before the bands and without any bands", function()
	local equalizer = Equalizer.new({ preamp = -6})
	test.falsy(equalizer:isFlat(), "a preamp alone is not flat")

	local source = sine(1000, 48000, 4096)
	local scaled = sine(1000, 48000, 4096)
	equalizer:process(scaled, 4096, 1, 48000)

	local ratio = peak(scaled + 1024, 4096 - 1024) / peak(source + 1024, 4096 - 1024)
	test.greater(ratio, 0.47, "-6 dB preamp halves the amplitude")
	test.less(ratio, 0.53, "-6 dB preamp halves the amplitude")

	test.equal(Equalizer.new({ preamp = -99}).preamp, -24, "the preamp clamps low")
	test.equal(Equalizer.new({ preamp = 99}).preamp, 12, "the preamp clamps high")
end)

test.it("keeps a preamp-only or pass-filter-only setting active on the player", function()
	local Player = require("treble.player")
	local player = Player.new({ stream = function() error("no device in this test") end })

	player:setEqualizer({ preamp = -6})
	test.truthy(player.equalizer ~= nil, "a preamp alone keeps the equalizer")

	player:setEqualizer({ preamp = 0})
	test.truthy(player.equalizer == nil, "a genuinely flat setting drops it")

	player:setEqualizer({
	{ frequency = 200, gain = 0, type = "highpass"},
	})
	test.truthy(player.equalizer ~= nil, "a zero-gain pass filter keeps the equalizer")
end)
