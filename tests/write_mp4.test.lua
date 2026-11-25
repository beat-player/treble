-- The iTunes writer, checked by writing a tag and reading it back through the same readers a library
-- uses. The fingerprint is compared as well: it hashes the audio through the sample table, so an
-- unshifted chunk offset shows up as a different track.
local test = require("lde-test")
local audio = require("treble.audio")
local write = require("treble.write.mp4")

---@param name string
---@return string
local function fixturePath(name)
	for _, prefix in ipairs({ "tests/fixtures/", "target/tests/fixtures/" }) do
		local path = prefix .. name
		local file = io.open(path, "rb")
		if file ~= nil then
			file:close()
			return path
		end
	end

	error("Missing fixture: " .. name)
end

---@param name string
---@return string
local function fixture(name)
	local file = assert(io.open(fixturePath(name), "rb"))
	local content = assert(file:read("*a"))
	file:close()

	return content
end

--- Copies a fixture to a temp file so the writer can replace it.
---@param name string
---@return string path
local function copyFixture(name)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	file:write(fixture(name))
	file:close()

	return path
end

---@param path string
---@return string data
local function read(path)
	local file = assert(io.open(path, "rb"))
	local data = assert(file:read("*a"))
	file:close()

	return data
end

---@param path string
---@param changes treble.TagChanges
local function apply(path, changes)
	local written, err = write(read(path), changes)
	assert(written, err)

	local file = assert(io.open(path, "wb"))
	file:write(written)
	file:close()
end

---@class tests.write.Mp4State
---@field fingerprint string?
---@field frameCount number
---@field duration number

---@param path string
---@return tests.write.Mp4State
local function state(path)
	local info = assert(audio.inspect(path))
	local source = assert(audio.fromPath(path))
	local result = {
		fingerprint = info.fingerprint,
		frameCount = source.frameCount,
		duration = info.duration,
	}
	source:close()

	return result
end

---@param value number
---@return string
local function be32(value)
	return string.char(
		math.floor(value / 16777216) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256,
		value % 256)
end

---@param kind string
---@param body string
---@return string
local function atom(kind, body)
	return be32(#body + 8) .. kind .. body
end

test.it("rewrites the tags of an m4a whose moov comes before its audio", function()
	local path = copyFixture("tagged.m4a")
	local before = state(path)
	local beforeTags = assert(audio.tags(path))
	local longTitle = string.rep("A much longer title ", 8)

	apply(path, {
		title = longTitle,
		artist = "Written Artist",
		albumArtist = "Written Album Artist",
		date = "2025-03-04",
		track = 7,
		disc = 2,
		genre = "Written Genre",
		comment = "Written Comment",
	})

	local tags = assert(audio.tags(path))

	test.equal(longTitle, tags.title)
	test.equal("Written Artist", tags.artist)
	test.equal("Written Album Artist", tags.albumArtist)
	test.equal("2025-03-04", tags.date)
	test.equal(7, tags.track)
	test.equal(12, tags.trackCount, "changing the track number keeps the total")
	test.equal(2, tags.disc, "the disc number changes and its total is not a field")
	test.equal("Written Genre", tags.genre)
	test.equal("Written Comment", tags.comment)
	test.equal("M4A Album", tags.album, "a field the change did not name is kept")
	test.equal(beforeTags.vendor, tags.vendor)

	test.truthy(tags.picture, "the cover is kept")
	test.equal("image/png", tags.picture.mime)
	test.equal(#beforeTags.picture.data, #tags.picture.data)

	local after = state(path)
	test.equal(before.fingerprint, after.fingerprint, "the chunk offsets moved with the audio")
	test.equal(before.frameCount, after.frameCount)
	test.equal(before.duration, after.duration)

	os.remove(path)
end)

test.it("adds items to an m4a whose audio comes before its moov", function()
	local path = copyFixture("tone.m4a")
	local before = state(path)
	local beforeTags = assert(audio.tags(path))

	apply(path, {
		title = "Written Title",
		artist = "Written Artist",
		album = "Written Album",
		albumArtist = "Written Album Artist",
		date = "2024-01-02",
		genre = "Rock",
		comment = "Written Comment",
		track = 2,
		trackCount = 9,
		disc = 1,
	})

	local tags = assert(audio.tags(path))

	test.equal("Written Title", tags.title)
	test.equal("Written Artist", tags.artist)
	test.equal("Written Album", tags.album)
	test.equal("Written Album Artist", tags.albumArtist)
	test.equal("2024-01-02", tags.date)
	test.equal("Rock", tags.genre)
	test.equal("Written Comment", tags.comment)
	test.equal(2, tags.track)
	test.equal(9, tags.trackCount)
	test.equal(1, tags.disc)
	test.equal(beforeTags.vendor, tags.vendor, "the encoder item is kept")

	local after = state(path)
	test.equal(before.fingerprint, after.fingerprint, "the audio did not move")
	test.equal(before.frameCount, after.frameCount)

	os.remove(path)
end)

test.it("removes the fields a change sets to false", function()
	local path = copyFixture("tone.m4a")

	apply(path, { title = "Title", genre = "Rock", comment = "A comment", track = 4, trackCount = 8 })
	apply(path, { genre = false, comment = false, track = false })

	local tags = assert(audio.tags(path))
	test.equal(nil, tags.genre)
	test.equal(nil, tags.comment)
	test.equal(nil, tags.track, "removing the track number drops the trkn item")
	test.equal(nil, tags.trackCount)
	test.equal("Title", tags.title, "a field the change did not name is kept")

	os.remove(path)
end)

test.it("reports a chunk offset that no longer fits in a 32 bit entry", function()
	local stco = atom("stco", "\0\0\0\0" .. be32(1) .. be32(0xFFFFFFF0))
	local stbl = atom("stbl", stco)
	local minf = atom("minf", stbl)
	local mdia = atom("mdia", minf)
	local trak = atom("trak", mdia)
	local moov = atom("moov", trak)
	local ftyp = atom("ftyp", "isom\0\0\0\0isom")
	local mdat = atom("mdat", "audio")

	local written, err = write(ftyp .. moov .. mdat, { title = string.rep("x", 64) })

	test.equal(nil, written)
	test.includes(err, "stco")
end)
