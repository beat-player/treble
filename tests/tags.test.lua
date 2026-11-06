local test = require("lde-test")
local audio = require("treble.audio")
local Tags = require("treble.tags")

-- The fixtures carry the same eight byte PNG as their attached picture.
local PNG_BYTES = 96

-- Tags built in memory keep these tests independent of an encoder agreeing
-- with the decoder about sizes and flags.

---@param value number
---@return string
local function synchsafe(value)
	return string.char(
		math.floor(value / 2097152) % 128,
		math.floor(value / 16384) % 128,
		math.floor(value / 128) % 128,
		value % 128
	)
end

---@param value number
---@return string
local function be32(value)
	return string.char(
		math.floor(value / 16777216) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256,
		value % 256
	)
end

---@param major number
---@param id string
---@param body string
---@param status number?
---@param format number?
---@return string
local function frame(major, id, body, status, format)
	local size = major == 4 and synchsafe(#body) or be32(#body)

	return id .. size .. string.char(status or 0, format or 0) .. body
end

---@param major number
---@param flags number
---@param frames string[]
---@return string
local function id3v2(major, flags, frames)
	local body = table.concat(frames)

	return "ID3" .. string.char(major, 0, flags) .. synchsafe(#body) .. body
end

test.it("reads ID3v2 tags and the attached picture from an mp3", function()
	local tags = assert(audio.tags("tests/fixtures/tagged.mp3"))

	test.equal(tags.title, "Test Title")
	test.equal(tags.artist, "Test Artist")
	test.equal(tags.album, "Test Album")
	test.equal(tags.track, 3)
	test.equal(tags.trackCount, 12)
	test.equal(tags.date, "2026")
	test.equal(tags.genre, "Test Genre")

	test.truthy(tags.picture, "the mp3 carries a picture")
	test.equal(tags.picture.mime, "image/png")
	test.equal(string.sub(tags.picture.data, 1, 4), "\137PNG", "the picture is the encoded image")
	test.equal(#tags.picture.data, PNG_BYTES)
end)

test.it("reads vorbis comments and the picture from an opus file", function()
	local tags = assert(audio.tags("tests/fixtures/tagged.opus"))

	test.equal(tags.title, "Opus Title")
	test.equal(tags.artist, "Opus Artist")
	test.equal(tags.album, "Opus Album")
	test.equal(tags.track, 5)
	test.equal(tags.date, "2026")
	test.equal(tags.genre, "Opus Genre")

	test.truthy(tags.picture, "the opus file carries a picture")
	test.equal(tags.picture.mime, "image/png")
	test.equal(string.sub(tags.picture.data, 1, 4), "\137PNG", "the base64 picture decodes back to the image")
	test.equal(#tags.picture.data, PNG_BYTES)
end)

test.it("reads vorbis comments and the picture from a flac file", function()
	local tags = assert(audio.tags("tests/fixtures/tagged.flac"))

	test.equal(tags.title, "Flac Title")
	test.equal(tags.artist, "Flac Artist")
	test.equal(tags.album, "Flac Album")
	test.equal(tags.track, 7)
	test.equal(tags.date, "2026")
	test.equal(tags.genre, "Flac Genre")

	test.truthy(tags.picture, "the flac file carries a picture")
	test.equal(tags.picture.mime, "image/png")
	test.equal(string.sub(tags.picture.data, 1, 4), "\137PNG")
	test.equal(#tags.picture.data, PNG_BYTES)
end)

test.it("reads INFO tags from a wav file", function()
	local tags = assert(audio.tags("tests/fixtures/tagged.wav"))

	test.equal(tags.title, "Wav Title")
	test.equal(tags.artist, "Wav Artist")
	test.equal(tags.album, "Wav Album")
	test.equal(tags.track, 9)
	test.equal(tags.date, "2026")
	test.equal(tags.genre, "Wav Genre")
end)

test.it("probes a file without reading its audio", function()
	local probe = assert(audio.probe("tests/fixtures/tone.flac"))

	test.equal(probe.format, "FLAC")
	test.equal(probe.sampleRate, 44100)
	test.equal(probe.channels, 1)
	test.equal(probe.duration, 0.25)
end)

test.it("probes an mp3 that states its length with a tag", function()
	local probe = assert(audio.probe("tests/fixtures/tagged.mp3"))

	test.equal(probe.format, "MP3")
	test.equal(probe.sampleRate, 44100)
	test.equal(probe.duration, 0.25)
end)

test.it("probes a wav's length from the data chunk, not the header buffer", function()
	local probe = assert(audio.probe("tests/fixtures/tagged.wav"))

	test.equal(probe.format, "WAV")
	test.equal(probe.sampleRate, 44100)
	test.equal(probe.channels, 1)
	test.equal(probe.duration, 0.25, "a 22050 byte mono 16 bit stream is a quarter second")
end)

test.it("reports a file with no tags", function()
	local tags, err = audio.tags("tests/fixtures/tone.wav")

	test.falsy(tags)
	test.truthy(err) ---@cast err -nil
	test.includes(err, "No tags")
end)

test.it("reports a file that cannot be probed", function()
	local probe, err = audio.probe("tests/fixtures/not-a-file.wav")

	test.falsy(probe)
	test.truthy(err) ---@cast err -nil
end)

test.it("reads an unsynchronised v2.4 comment with a data length indicator", function()
	-- The exact frame a player choked on: flags 0x0003 mark unsynchronisation
	-- and a four byte data length indicator, and the text holds a FF byte.
	local body = "\0\0\0\22" .. "\1eng"
		.. "\255\0\254\0\0\255\0\254\67\0\97\0\110\0\97\0\100\0\97\0"
	local tags = Tags.fromId3v2(id3v2(4, 0, { frame(4, "COMM", body, 0, 0x03) }))

	test.equal(tags.comment, "Canada")
end)

test.it("reads a v2.4 title with a data length indicator and unsynchronisation", function()
	-- "ÿ" in UTF-16LE: its FF byte is stored unsynchronised as FF 00.
	local content = "\1\255\254\255\0"
	local stored = "\1\255\254\255\0\0"
	local body = synchsafe(#content) .. stored
	local tags = Tags.fromId3v2(id3v2(4, 0, { frame(4, "TIT2", body, 0, 0x03) }))

	test.equal(tags.title, "\195\191")
end)

test.it("turns a Latin-1 v2.3 title into UTF-8", function()
	local tags = Tags.fromId3v2(id3v2(3, 0, { frame(3, "TIT2", "\0Caf\233") }))

	test.equal(tags.title, "Caf\195\169")
end)

test.it("reads both UTF-16 byte orders from a title", function()
	local big = Tags.fromId3v2(id3v2(3, 0, { frame(3, "TIT2", "\1\254\255\0\67\0\97\0\102\0\233") }))
	local little = Tags.fromId3v2(id3v2(3, 0, { frame(3, "TIT2", "\1\255\254\67\0\97\0\102\0\233\0") }))

	test.equal(big.title, "Caf\195\169", "FE FF is big endian")
	test.equal(little.title, "Caf\195\169", "FF FE is little endian")
end)

test.it("skips compressed and encrypted frames in a v2.4 tag", function()
	local compressed = frame(4, "TIT2", "\8\0\0\0garbage", 0, 0x08)
	local encrypted = frame(4, "TPE1", "\1\2\3", 0, 0x04)
	local album = frame(4, "TALB", "\3Album", 0, 0)
	local tags = Tags.fromId3v2(id3v2(4, 0, { compressed, encrypted, album }))

	test.equal(tags.title, nil)
	test.equal(tags.artist, nil)
	test.equal(tags.album, "Album")
end)

test.it("undoes v2.3 unsynchronisation before walking the frames", function()
	-- The whole tag body is unsynchronised in 2.3, so the FF of "ÿ" is stored
	-- as FF 00 and the frame header states the unescaped size.
	local stored = "\0AB\255\0"
	local tag = id3v2(3, 0x80, { "TIT2" .. be32(4) .. "\0\0" .. stored })
	local tags = Tags.fromId3v2(tag)

	test.equal(tags.title, "AB\195\191")
end)

