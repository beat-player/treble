-- The ID3 writer, checked by writing a tag and reading it back through the same readers a library
-- uses. The decoded audio is compared as well, so a tag that moved the audio is a failure.
local test = require("lde-test")
local audio = require("treble.audio")
local Tags = require("treble.tags")
local write = require("treble.write.id3")

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

---@class tests.write.State
---@field fingerprint string?
---@field frameCount number
---@field duration number

---@param path string
---@return tests.write.State
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

---@param value number
---@return string
local function synchsafe(value)
	return string.char(
		math.floor(value / 2097152) % 128,
		math.floor(value / 16384) % 128,
		math.floor(value / 128) % 128,
		value % 128)
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

test.it("rewrites the tag of an mp3 and keeps the rest of it", function()
	local path = copyFixture("tagged.mp3")
	local before = state(path)
	local beforeTags = assert(audio.tags(path))

	apply(path, {
		title = "Written Title",
		artist = "Written Artist",
		albumArtist = "Written Album Artist",
		date = "2025-03-04",
		track = 5,
		genre = "Written Genre",
		comment = "Written Comment",
		disc = 2,
	})

	local tags = assert(audio.tags(path))

	test.equal("Written Title", tags.title)
	test.equal("Written Artist", tags.artist)
	test.equal("Written Album Artist", tags.albumArtist)
	test.equal("2025-03-04", tags.date)
	test.equal(5, tags.track)
	test.equal(12, tags.trackCount, "changing the track number keeps the total")
	test.equal(2, tags.disc)
	test.equal("Written Genre", tags.genre)
	test.equal("Written Comment", tags.comment)
	test.equal("Test Album", tags.album, "a field the change did not name is kept")
	test.equal(beforeTags.vendor, tags.vendor)

	test.truthy(tags.picture, "the picture is kept")
	test.equal("image/png", tags.picture.mime)
	test.equal(#beforeTags.picture.data, #tags.picture.data)

	local after = state(path)
	test.equal(before.fingerprint, after.fingerprint, "the audio is untouched")
	test.equal(before.frameCount, after.frameCount)
	test.equal(before.duration, after.duration)

	os.remove(path)
end)

test.it("creates a tag in front of an mp3 that has none", function()
	local path = copyFixture("tone-plain.mp3")
	local before = state(path)

	apply(path, { title = "New Title", artist = "New Artist", track = 9 })

	local tags = assert(audio.tags(path))
	test.equal("New Title", tags.title)
	test.equal("New Artist", tags.artist)
	test.equal(9, tags.track)
	test.equal(nil, tags.trackCount)

	local after = state(path)
	test.equal(before.fingerprint, after.fingerprint)
	test.equal(before.frameCount, after.frameCount)

	apply(path, { title = false })

	local removed = assert(audio.tags(path))
	test.equal(nil, removed.title, "false removes the frame")
	test.equal("New Artist", removed.artist)

	os.remove(path)
end)

test.it("leaves an ID3v1 tag at the end of the file", function()
	local audioBytes = fixture("tone-plain.mp3")
	local id3v1 = "TAG" .. string.rep("\0", 125)

	local written = assert(write(audioBytes .. id3v1, { title = "Tagged" }))
	test.equal(id3v1, written:sub(-128))
end)

test.it("drops TYER and TDAT when a v2.3 date changes and keeps unknown frames", function()
	local audioBytes = fixture("tone-plain.mp3")
	local content = id3v2(3, 0, {
		frame(3, "TIT2", "\0Old Title"),
		frame(3, "TYER", "\0" .. "2020"),
		frame(3, "TDAT", "\0" .. "0102"),
		frame(3, "PRIV", "owner\0secret"),
	}) .. audioBytes

	local written = assert(write(content, { title = "New Title", date = "2021-05-06" }))

	test.truthy(written:find("TDRC", 1, true), "the date is written as TDRC")
	test.falsy(written:find("TYER", 1, true), "v2.3's year frame is gone")
	test.falsy(written:find("TDAT", 1, true), "v2.3's day frame is gone")
	test.truthy(written:find("PRIV", 1, true), "an unknown frame is kept")
	test.truthy(written:find("owner\0secret", 1, true), "its payload is kept")
	test.equal(audioBytes, written:sub(-#audioBytes), "the audio follows the tag")

	local tags = assert(Tags.fromId3v2(written))
	test.equal("New Title", tags.title)
	test.equal("2021-05-06", tags.date)
end)

test.it("undoes a v2.4 frame's unsynchronisation and data length indicator", function()
	local audioBytes = fixture("tone-plain.mp3")
	local content = id3v2(4, 0, {
		frame(4, "TIT2", "\3A\255\0B", 0, 0x02),
		frame(4, "TALB", "\0\0\0\5" .. "\3Album", 0, 0x01),
	}) .. audioBytes

	local written = assert(write(content, { date = "2024" }))
	local tags = assert(Tags.fromId3v2(written))

	test.equal("A\255B", tags.title, "the frame contents come back unescaped")
	test.equal("Album", tags.album, "the data length indicator is not part of the text")
end)

test.it("undoes a v2.4 tag wide unsynchronisation flag", function()
	local audioBytes = fixture("tone-plain.mp3")
	local content = id3v2(4, 0x80, {
		frame(4, "TIT2", "\3A\255\0B"),
	}) .. audioBytes

	local written = assert(write(content, { date = "2024" }))
	local tags = assert(Tags.fromId3v2(written))

	test.equal("A\255B", tags.title, "the frame is unescaped even without its own flag")
end)

test.it("refuses to rewrite a v2.2 tag", function()
	local written, err = write(id3v2(2, 0, {}) .. fixture("tone-plain.mp3"), { title = "No" })

	test.equal(nil, written)
	test.includes(err, "ID3v2.2")
end)
