local test = require("lde-test")
local audio = require("treble.audio")

-- The fixtures carry the same eight byte PNG as their attached picture.
local PNG_BYTES = 96

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
