-- What a scan asks a file before it opens a decoder: the properties, the text tags, whether there
-- is art, and how long it plays. The pictures themselves stay on disk.
local test = require("lde-test")
local audio = require("treble.audio")

local function fixture(name)
	for _, prefix in ipairs({ "tests/fixtures/", "target/tests/fixtures/" }) do
		local path = prefix .. name
		if io.open(path, "rb") ~= nil then return path end
	end

	error("Missing fixture: " .. name)
end

--- A duration is stated by a container in whole frames, and the encoder's own frame count may
--- include padding. What a scan needs is close enough to show the right minute and second.
---@param actual number
---@param expected number
local function near(actual, expected)
	return math.abs(actual - expected) < 0.12
end

local TAGGED = {
	{ file = "tagged.mp3", format = "MP3", title = "Test Title", artist = "Test Artist",
		album = "Test Album", track = 3, date = "2026", genre = "Test Genre", picture = true },
	{ file = "tagged.flac", format = "FLAC", title = "Flac Title", artist = "Flac Artist",
		album = "Flac Album", track = 7, date = "2026", genre = "Flac Genre", picture = true },
	{ file = "tagged.opus", format = "Opus", title = "Opus Title", artist = "Opus Artist",
		album = "Opus Album", track = 5, date = "2026", genre = "Opus Genre", picture = true,
		rate = 48000 },
	{ file = "tagged.wav", format = "WAV", title = "Wav Title", artist = "Wav Artist",
		album = "Wav Album", track = 9, date = "2026", genre = "Wav Genre", picture = false },
}

for _, case in ipairs(TAGGED) do
	test.it("reads " .. case.file .. " without a decoder", function()
		local info = assert(audio.inspect(fixture(case.file)))
		local tags = assert(info.tags)

		test.equal(info.format, case.format)
		test.equal(info.sampleRate, case.rate or 44100, "the sample rate is in the container header")
		test.equal(info.channels, 1)
		test.equal(info.hasPicture, case.picture)
		test.falsy(tags.picture, "the scan does not copy the picture")

		test.equal(tags.title, case.title)
		test.equal(tags.artist, case.artist)
		test.equal(tags.album, case.album)
		test.equal(tags.track, case.track)
		test.equal(tags.date, case.date)
		test.equal(tags.genre, case.genre)
		test.truthy(near(info.duration, 0.25), "the duration is the file's, near enough")
	end)
end

for _, name in ipairs({ "tone.mp3", "tone.flac", "tone.opus", "tone.wav" }) do
	test.it("reads the properties of " .. name .. " with no tags", function()
		local info = assert(audio.inspect(fixture(name)))

		test.equal(info.channels, 1)
		test.truthy(near(info.duration, 0.25))
		test.falsy(info.tags, "there is no text tag to report")
		test.falsy(info.hasPicture)
	end)
end

test.it("counts the frames of an MP3 that does not say how many it has", function()
	-- Ten MPEG-1 Layer III frames at 128 kbps and ten at 320, with no Xing, Info or VBRI frame to
	-- say so: a length worked out from the first frame's bitrate would be far off. Only the headers
	-- are read, so the audio can be silence; the ID3v1 tag after the last frame ends the stream.
	local function frame(bitrateBits, length)
		return string.char(0xFF, 0xFB, bitrateBits, 0xC0) .. string.rep("\0", length - 4)
	end
	local parts = {}
	for _ = 1, 10 do parts[#parts + 1] = frame(0x90, 417) end
	for _ = 1, 10 do parts[#parts + 1] = frame(0xE0, 1044) end
	parts[#parts + 1] = "TAG" .. string.rep("\0", 125)

	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	file:write(table.concat(parts))
	file:close()
	local info = audio.inspect(path)
	os.remove(path)

	assert(info)
	test.equal(info.format, "MP3")
	test.equal(info.channels, 1)
	test.truthy(math.abs(info.duration - 20 * 1152 / 44100) < 1e-9, "every frame is counted, and only frames")
end)

test.it("reports a file it cannot read, naming it", function()
	local info, err = audio.inspect("tests/fixtures/not-a-file.wav")

	test.falsy(info)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "not-a-file.wav")
end)

test.it("agrees with the decoder about the properties of a file", function()
	for _, case in ipairs(TAGGED) do
		local path = fixture(case.file)
		local probe = assert(audio.probe(path))
		local info = assert(audio.inspect(path))

		test.equal(info.format, probe.format)
		test.equal(info.sampleRate, probe.sampleRate)
		test.equal(info.channels, probe.channels)
		test.truthy(near(info.duration, probe.duration))
	end
end)
