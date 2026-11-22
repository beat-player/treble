local test = require("lde-test")
local buffer = require("string.buffer")
local ffi = require("ffi")
local Flac = require("treble.formats.flac")
local Mp3 = require("treble.formats.mp3")
local Opus = require("treble.formats.opus")
local Aac = require("treble.formats.aac")

local SampleBuffer = ffi.typeof("int16_t[?]")

-- The fixtures are a 0.25s 440 Hz tone: 11025 frames at 44100 Hz as mp3, 12000
-- frames at 48000 Hz as opus. The m4a fixtures are one second of the same tone
-- as stereo AAC.
local TONE_SECONDS = 0.25
local TONE_HZ = 440
local TONE_CROSSINGS = TONE_HZ * TONE_SECONDS * 2

local M4A_SECONDS = 1
local M4A_FRAMES = 44100
local M4A_CROSSINGS = TONE_HZ * M4A_SECONDS * 2

---@param value number
---@return string
local function be16(value)
	return string.char(math.floor(value / 256) % 256, value % 256)
end

---@param value number
---@return string
local function be32(value)
	return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256, value % 256)
end

---@param kind string
---@param body string
---@return string
local function box(kind, body)
	return be32(#body + 8) .. kind .. body
end

--- lde runs tests from the package root, but not from a fixed place, so try both.
---@param name string
---@return string path
---@return string.buffer content
local function fixture(name)
	for _, prefix in ipairs({ "tests/fixtures/", "target/tests/fixtures/" }) do
		local file = io.open(prefix .. name, "rb")
		if file then
			local content = buffer.new()
			content:put(file:read("*all"))
			file:close()
			return prefix .. name, content
		end
	end

	error("Missing fixture: " .. name)
end

--- Counts how often the signal crosses zero, which for the tone fixture says
--- whether the decoded samples are the audio that went in.
---@param samples ffi.cdata*
---@param count number
local function crossings(samples, count)
	local total = 0
	local previous = 0

	for i = 0, count - 1 do
		local sample = samples[i]
		if sample ~= 0 and (sample < 0) ~= (previous < 0) then
			total = total + 1
		end
		if sample ~= 0 then
			previous = sample
		end
	end

	return total
end

--- A source may return fewer frames than asked for, so fill a request by
--- reading until it runs dry.
---@param source treble.Source
---@param out ffi.cdata*
---@param frames number
local function readFrames(source, out, frames)
	local total = 0

	while total < frames do
		local read = source:read(out + total * source.channels, frames - total)
		if read == 0 then
			break
		end
		total = total + read
	end

	return total
end

--- Reads to the end of a source that does not know its own length.
---@param source treble.Source
---@return number frames
---@return number crossings
local function drain(source)
	local chunk = SampleBuffer(4096 * source.channels)
	local frames = 0
	local crossed = 0

	while true do
		local read = source:read(chunk, 4096)
		if read == nil or read == 0 then
			break
		end

		crossed = crossed + crossings(chunk, read * source.channels)
		frames = frames + read
	end

	return frames, crossed
end

---@param source treble.Source
---@return ffi.cdata* samples
---@return number frames
local function readAll(source)
	local samples = SampleBuffer(source.frameCount * source.channels)

	return samples, readFrames(source, samples, source.frameCount)
end

---@param measured number
---@param expected number
---@param tolerance number
local function isNear(measured, expected, tolerance)
	return math.abs(measured - expected) <= tolerance
end

test.it("decodes a whole mp3 file", function()
	local path = fixture("tone.mp3")
	local source = assert(Mp3.fromPath(path))

	test.equal(source.channels, 1)
	test.equal(source.sampleRate, 44100)
	test.truthy(isNear(source.frameCount, TONE_SECONDS * 44100, 1152), "frame count within one mp3 frame")

	local samples, frames = readAll(source)
	test.equal(frames, source.frameCount)
	-- One crossing per half cycle, so a 440 Hz tone crosses zero 220 times in 0.25s.
	test.truthy(isNear(crossings(samples, frames * source.channels), TONE_CROSSINGS, TONE_CROSSINGS * 0.1), "decode is the tone that went in")
	source:close()
end)

test.it("decodes an mp3 from memory", function()
	local _, content = fixture("tone.mp3")
	local source = assert(Mp3.fromMemory(content:ref(), #content))

	test.equal(source.channels, 1)
	test.equal(source.sampleRate, 44100)

	local samples, frames = readAll(source)
	test.truthy(isNear(crossings(samples, frames * source.channels), TONE_CROSSINGS, TONE_CROSSINGS * 0.1), "memory decode is the tone that went in")
	source:close()
end)

test.it("seeks into an mp3 exactly", function()
	local path = fixture("tone.mp3")
	local source = assert(Mp3.fromPath(path))
	local samples = readAll(source)

	local middle = math.floor(source.frameCount / 2)
	test.truthy(source:seek(middle), "seek reports success")

	local slice = SampleBuffer(512 * source.channels)
	test.equal(readFrames(source, slice, 512), 512)
	for i = 0, 511 * source.channels - 1 do
		test.equal(slice[i], samples[middle * source.channels + i], "sample " .. i .. " after the seek")
	end
	source:close()
end)

test.it("decodes a whole opus file", function()
	local path = fixture("tone.opus")
	local source = assert(Opus.fromPath(path))

	test.equal(source.channels, 1)
	-- Opus always decodes at 48 kHz, whatever the input was encoded from.
	test.equal(source.sampleRate, 48000)
	test.truthy(isNear(source.frameCount, 12000, 500), "frame count is the encoded length")

	local samples, frames = readAll(source)
	test.equal(frames, source.frameCount)
	test.truthy(isNear(crossings(samples, frames * source.channels), TONE_CROSSINGS, TONE_CROSSINGS * 0.1), "decode is the tone that went in")
	source:close()
end)

test.it("decodes opus from memory", function()
	local _, content = fixture("tone.opus")
	local source = assert(Opus.fromMemory(content:ref(), #content))

	test.equal(source.channels, 1)
	test.truthy(isNear(source.frameCount, 12000, 500), "frame count is the encoded length")
	source:close()
end)

test.it("seeks into an opus stream", function()
	local path = fixture("tone.opus")
	local source = assert(Opus.fromPath(path))

	local middle = math.floor(source.frameCount / 2)
	test.truthy(source:seek(middle), "seek reports success")

	local slice = SampleBuffer(2048 * source.channels)
	test.equal(readFrames(source, slice, 2048), 2048)
	-- The tone keeps playing after the seek, so its pitch has to survive it.
	local expected = TONE_HZ * (2048 / source.sampleRate) * 2
	test.truthy(isNear(crossings(slice, 2048 * source.channels), expected, expected * 0.2), "the tone continues after the seek")
	source:close()
end)

test.it("decodes a whole flac file", function()
	local path = fixture("tone.flac")
	local source = assert(Flac.fromPath(path))

	test.equal(source.channels, 1)
	test.equal(source.sampleRate, 44100)
	test.equal(source.frameCount, TONE_SECONDS * 44100, "the stream info gives the exact length")

	local samples, frames = readAll(source)
	test.equal(frames, source.frameCount)
	test.truthy(isNear(crossings(samples, frames * source.channels), TONE_CROSSINGS, TONE_CROSSINGS * 0.1), "decode is the tone that went in")
	source:close()
end)

test.it("seeks into a flac file exactly", function()
	local path = fixture("tone.flac")
	local source = assert(Flac.fromPath(path))
	local samples = readAll(source)

	local middle = math.floor(source.frameCount / 2)
	test.truthy(source:seek(middle), "seek reports success")

	local slice = SampleBuffer(512 * source.channels)
	test.equal(readFrames(source, slice, 512), 512)
	for i = 0, 511 * source.channels - 1 do
		test.equal(slice[i], samples[middle * source.channels + i], "sample " .. i .. " after the seek")
	end
	source:close()
end)

test.it("decodes flac from memory", function()
	local _, content = fixture("tone.flac")
	local source = assert(Flac.fromMemory(content:ref(), #content))

	test.equal(source.sampleRate, 44100)
	test.equal(source.frameCount, TONE_SECONDS * 44100)
	source:close()
end)

test.it("decodes a whole m4a file", function()
	local path = fixture("tagged.m4a")
	local source = assert(Aac.fromPath(path))

	test.equal(source.channels, 2)
	test.equal(source.sampleRate, 44100)
	-- The edit list trims the encoder's priming, so one second is one second.
	test.equal(source.frameCount, M4A_FRAMES, "the duration follows the edit list")

	local samples, frames = readAll(source)
	test.equal(frames, source.frameCount)
	test.truthy(isNear(crossings(samples, frames * source.channels), M4A_CROSSINGS, M4A_CROSSINGS * 0.1), "decode is the tone that went in")
	source:close()
end)

test.it("decodes an m4a from memory", function()
	local _, content = fixture("tone.m4a")
	local source = assert(Aac.fromMemory(content:ref(), #content))

	test.equal(source.channels, 2)
	test.equal(source.sampleRate, 44100)
	test.equal(source.frameCount, M4A_FRAMES)

	local samples, frames = readAll(source)
	test.equal(frames, source.frameCount)
	test.truthy(isNear(crossings(samples, frames * source.channels), M4A_CROSSINGS, M4A_CROSSINGS * 0.1), "memory decode is the tone that went in")
	source:close()
end)

test.it("seeks into an m4a exactly", function()
	local path = fixture("tagged.m4a")
	local source = assert(Aac.fromPath(path))
	local samples = readAll(source)

	local middle = 20000
	test.truthy(source:seek(middle), "seek reports success")

	local slice = SampleBuffer(512 * source.channels)
	test.equal(readFrames(source, slice, 512), 512)

	-- FDK's reset leaves the first frame's overlap state a rounding step away
	-- from the continuous decode, so compare the samples rather than their bits.
	local largest = 0
	for i = 0, 511 * source.channels - 1 do
		largest = math.max(largest, math.abs(slice[i] - samples[middle * source.channels + i]))
	end
	test.less(largest, 2, "the seek lands where the continuous decode did")
	source:close()
end)

test.it("rejects an MP4 whose sound track is not AAC", function()
	local alacEntry = box("alac", string.rep("\0", 6) .. be16(1) .. string.rep("\0", 8)
		.. be16(2) .. be16(16) .. be16(0) .. be16(0) .. be32(44100 * 65536))

	local stsd = box("stsd", "\0\0\0\0" .. be32(1) .. alacEntry)
	local mdhd = box("mdhd", "\0\0\0\0" .. be32(0) .. be32(0) .. be32(44100) .. be32(0)
		.. "\0\0\0\0")
	local hdlr = box("hdlr", "\0\0\0\0" .. be32(0) .. "soun" .. string.rep("\0", 8))
	local stts = box("stts", "\0\0\0\0" .. be32(0))
	local stsc = box("stsc", "\0\0\0\0" .. be32(0))
	local stco = box("stco", "\0\0\0\0" .. be32(0))

	local stbl = box("stbl", stsd .. stts .. stsc .. stco)
	local mdia = box("mdia", mdhd .. hdlr .. box("minf", stbl))
	local moov = box("moov", box("trak", mdia))
	local contentBuffer = buffer.new()
	contentBuffer:put(box("ftyp", "M4A \0\0\0\0") .. moov)

	local source, err = Aac.fromMemory(contentBuffer:ref(), #contentBuffer)
	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Unsupported codec")
end)

test.it("plays an mp3 that does not state its length without scanning it", function()
	local path = fixture("tone-plain.mp3")
	local source = assert(Mp3.fromPath(path))

	test.equal(source.frameCount, 0, "no tag means no length, and finding one would mean a full scan")

	local frames = drain(source)
	local seconds = frames / source.sampleRate

	-- Without the tag there is no gapless information either, so the encoder delay
	-- and padding stay in: 0.287s for a 0.25s tone, which is what ffprobe reports.
	-- The samples themselves are covered by the tagged fixture, where the delay and
	-- padding are trimmed and the tone can be counted exactly.
	test.greater(seconds, TONE_SECONDS)
	test.less(seconds, TONE_SECONDS + 0.05)
	source:close()
end)

test.it("recognises which content belongs to which format", function()
	local _, mp3 = fixture("tone.mp3")
	local _, opus = fixture("tone.opus")
	local _, flac = fixture("tone.flac")
	local _, m4a = fixture("tone.m4a")
	local mp3Content = mp3:get()
	local opusContent = opus:get()
	local flacContent = flac:get()
	local m4aContent = m4a:get()

	test.truthy(Flac.isValid(flacContent))
	test.falsy(Flac.isValid(mp3Content), "an mp3 is not flac")
	test.falsy(Mp3.isValid(flacContent), "flac is not an mp3")

	test.truthy(Mp3.isValid(mp3Content))
	test.truthy(Opus.isValid(opusContent))
	test.falsy(Mp3.isValid(opusContent), "an ogg page is not an mp3")
	test.falsy(Opus.isValid(mp3Content), "an mp3 is not an ogg opus stream")

	test.truthy(Aac.isValid(m4aContent), "an m4a starts with an ftyp box")
	test.falsy(Aac.isValid(mp3Content), "an mp3 is not an mp4")
	test.falsy(Aac.isValid(flacContent), "flac is not an mp4")
end)

test.it("reports a file it cannot decode", function()
	local source, err = Mp3.fromPath("tests/fixtures/no-such-file.mp3")
	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Failed to open MP3 file")
end)
