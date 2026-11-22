local test = require("lde-test")
local ffi = require("ffi")
local buffer = require("string.buffer")
local fixture = require("tests.fixtures.wav")
local audio = require("treble.audio")

-- Sources read from caller memory, so the buffers have to outlive the tests.
local held = {}

---@param content string
local function fromMemory(content)
	local content_ = buffer.new()
	content_:put(content)
	held[#held + 1] = content_

	return audio.fromMemory(ffi.cast("const char*", content_:ref()), #content_)
end

test.it("opens a wav from a path", function()
	local source = assert(audio.fromPath("tests/fixtures/tone.wav"))

	test.equal(source.sampleRate, 44100)
	test.equal(source.channels, 1)
end)

test.it("opens a flac from a path", function()
	local source = assert(audio.fromPath("tests/fixtures/tone.flac"))

	test.equal(source.sampleRate, 44100)
	test.equal(source.channels, 1)
end)

test.it("opens an mp3 from a path", function()
	local source = assert(audio.fromPath("tests/fixtures/tone.mp3"))

	test.equal(source.sampleRate, 44100)
	test.equal(source.channels, 1)
end)

test.it("opens an opus from a path", function()
	local source = assert(audio.fromPath("tests/fixtures/tone.opus"))

	test.equal(source.sampleRate, 48000)
	test.equal(source.channels, 1)
end)

test.it("opens an m4a from a path", function()
	local source = assert(audio.fromPath("tests/fixtures/tone.m4a"))

	test.equal(source.sampleRate, 44100)
	test.equal(source.channels, 2)
	test.equal(source.frameCount, 44100)
end)

test.it("opens memory by sniffing its first bytes", function()
	local source = assert(fromMemory(fixture.build({ sampleRate = 11025, frames = 64 })))

	test.equal(source.sampleRate, 11025)
	test.equal(source.frameCount, 64)
end)

test.it("reports content it has no decoder for", function()
	local source, err = fromMemory("this is not audio, not even close, really")
	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Unsupported audio format")
end)

test.it("reports a path it cannot open", function()
	local source, err = audio.fromPath("tests/fixtures/no-such-file.wav")
	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Failed to open audio file")
end)

test.it("reports a file whose bytes it does not know", function()
	local source, err = audio.fromPath("README.md")
	test.falsy(source)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "Unsupported audio format")
end)

test.it("recognises what it can open", function()
	test.truthy(audio.isValid(fixture.build()))
	test.falsy(audio.isValid("nothing to see here, move along please"))
end)
