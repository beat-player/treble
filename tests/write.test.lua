local test = require("lde-test")
local audio = require("treble.audio")

local FIXTURES = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") .. "fixtures/"

---@param name string
---@return string
local function copy(name)
	local source = assert(io.open(FIXTURES .. name, "rb"))
	local data = source:read("*a")
	source:close()
	local path = os.tmpname() .. "-" .. name
	local out = assert(io.open(path, "wb"))
	out:write(data)
	out:close()
	return path
end

--- How many frames the file decodes to, read to the end.
---@param path string
---@return number
local function framesOf(path)
	local source = assert(audio.fromPath(path))
	local pcm = require("ffi").new("int16_t[?]", 4096 * source.channels)
	local decoded = 0
	while true do
		local got = source:read(pcm, 4096)
		if got == nil or got == 0 then break end
		decoded = decoded + got
	end
	source:close()
	return decoded
end

for _, name in ipairs({ "tagged.opus", "tone.opus", "tagged.flac", "tone.flac" }) do
	test.it("writes tags into " .. name, function()
		local path = copy(name)
		local before = assert(audio.inspect(path))
		local beforeTags = audio.tags(path) or {}
		local frames = framesOf(path)

		assert(audio.writeTags(path, { title = "Nüe Title", artist = "Someone", track = 7, date = false }))

		local tags = assert(audio.tags(path))
		test.equal(tags.title, "Nüe Title")
		test.equal(tags.artist, "Someone")
		test.equal(tags.track, 7)
		test.equal(tags.date, nil)
		test.equal(tags.album, beforeTags.album)
		test.equal(tags.genre, beforeTags.genre)
		test.equal(tags.picture ~= nil, beforeTags.picture ~= nil)
		test.equal(framesOf(path), frames)

		local after = assert(audio.inspect(path))
		test.equal(after.fingerprint, before.fingerprint)
		test.equal(after.duration, before.duration)
		test.equal(after.tags.title, "Nüe Title")
		os.remove(path)
	end)

	test.it("keeps " .. name .. " playable when the tags outgrow their pages", function()
		local path = copy(name)
		local before = assert(audio.inspect(path))
		-- The title comes before the comment, so a reader that stops early still finds a tag.
		local long = string.rep("long comment ", 20000)
		assert(audio.writeTags(path, { title = "Short", comment = long }))
		test.equal(assert(audio.tags(path)).comment, long)
		local after = assert(audio.inspect(path))
		test.equal(after.fingerprint, before.fingerprint)
		test.equal(after.duration, before.duration)

		-- And back down again, which takes pages away.
		assert(audio.writeTags(path, { comment = false }))
		test.equal((audio.tags(path) or {}).comment, nil)
		test.equal(assert(audio.inspect(path)).fingerprint, before.fingerprint)
		os.remove(path)
	end)
end

test.it("refuses a field it does not know", function()
	local path = copy("tone.opus")
	local ok, err = audio.writeTags(path, { colour = "red" } --[[@as any]])
	test.falsy(ok)
	test.truthy(err:find("colour", 1, true))
	os.remove(path)
end)
