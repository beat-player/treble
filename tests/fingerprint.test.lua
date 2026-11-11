-- A track is known by its audio. These tests build, from the fixtures, the changes a library
-- sees all the time -- tags grown, comments rewritten, a picture pushed onto another page --
-- and check that the fingerprint stays put. They also check that it moves when the audio does.
local bit = require("bit")

---@class tests.TestModule
---@field it fun(name: string, body: fun())
---@field equal fun(expected: any, actual: any, message: string?)
---@field truthy fun(value: any, message: string?)
---@field falsy fun(value: any, message: string?)

---@class tests.WavFixture
---@field build fun(opts: table): string
---@field pcm16 fun(opts: table): string

-- lde supplies lde-test at runtime, so there is no file for lye to resolve on disk.
---@diagnostic disable-next-line: missing-module
local test = require("lde-test") ---@cast test tests.TestModule
local audio = require("treble.audio") ---@cast audio treble.audio
local wavFixture = require("tests.fixtures.wav") ---@cast wavFixture tests.WavFixture

-- ────────────────────────────────────────────────────────────────
-- fixtures and temp files
-- ────────────────────────────────────────────────────────────────

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

---@param content string
---@return treble.audio.Inspect
local function inspectContent(content)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	file:write(content)
	file:close()

	local info = audio.inspect(path)
	os.remove(path)

	if info == nil then error("The variant could not be inspected") end

	return info
end

---@param content string
---@return string
local function fingerprint(content)
	local info = inspectContent(content)
	local value = info.fingerprint

	if value == nil then error("The variant has no fingerprint") end
	test.equal(#value, 16, "a fingerprint is 16 hex digits")
	test.truthy(value:match("^[0-9a-f]+$") ~= nil, "a fingerprint is lowercase hex")

	return value
end

---@param content string
---@param at number 1 based
---@return string
local function mutate(content, at)
	local byte = content:byte(at)
	if byte == nil then error("Byte " .. at .. " is past the content") end

	return content:sub(1, at - 1) .. string.char(bit.bxor(byte, 0xFF) % 256) .. content:sub(at + 1)
end

-- ────────────────────────────────────────────────────────────────
-- byte handling
-- ────────────────────────────────────────────────────────────────

---@param content string
---@param at number 1 based
---@return number
local function le32(content, at)
	return (content:byte(at) or 0) + (content:byte(at + 1) or 0) * 256
		+ (content:byte(at + 2) or 0) * 65536 + (content:byte(at + 3) or 0) * 16777216
end

---@param content string
---@param at number 1 based
---@return number
local function be24(content, at)
	return (content:byte(at) or 0) * 65536 + (content:byte(at + 1) or 0) * 256
		+ (content:byte(at + 2) or 0)
end

---@param value number
---@return string
local function le32Bytes(value)
	return string.char(value % 256, math.floor(value / 256) % 256,
		math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

---@param value number
---@return string
local function be32Bytes(value)
	return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256, value % 256)
end

---@param value number
---@return string
local function le64Bytes(value)
	local parts = {}
	for _ = 1, 8 do
		parts[#parts + 1] = string.char(value % 256)
		value = math.floor(value / 256)
	end

	return table.concat(parts)
end

---@param content string
---@param at number 1 based
---@return number
local function synchsafe(content, at)
	return (content:byte(at) or 0) * 2097152 + (content:byte(at + 1) or 0) * 16384
		+ (content:byte(at + 2) or 0) * 128 + (content:byte(at + 3) or 0)
end

---@param value number
---@return string
local function synchsafeBytes(value)
	return string.char(bit.band(bit.rshift(value, 21), 0x7F),
		bit.band(bit.rshift(value, 14), 0x7F),
		bit.band(bit.rshift(value, 7), 0x7F),
		bit.band(value, 0x7F))
end

-- ────────────────────────────────────────────────────────────────
-- MP3
-- ────────────────────────────────────────────────────────────────

--- Adds an ID3v2 frame and padding: the audio moves, its bytes do not.
---@param content string
---@return string
local function growId3Tag(content)
	if content:sub(1, 3) ~= "ID3" then error("The fixture is not ID3 tagged") end

	local size = synchsafe(content, 7)
	local frame = "TXXX" .. be32Bytes(5) .. "\0\0" .. "hello"
	local padding = string.rep("\0", 64)

	return content:sub(1, 6) .. synchsafeBytes(size + #frame + #padding)
		.. frame .. content:sub(11, 10 + size) .. padding .. content:sub(11 + size)
end

---@param content string
---@return number 1 based
local function id3AudioAt(content)
	if content:sub(1, 3) ~= "ID3" then
		for at = 1, #content - 1 do
			if content:byte(at) == 0xFF and (content:byte(at + 1) or 0) >= 0xE0 then return at end
		end
		error("No MPEG frame in the fixture")
	end

	return 11 + synchsafe(content, 7)
end

-- ────────────────────────────────────────────────────────────────
-- FLAC
-- ────────────────────────────────────────────────────────────────

---@class tests.FlacBlock
---@field kind number
---@field last boolean
---@field body string

--- Adds a Vorbis comment and resizes the padding block.
---@param content string
---@return string
local function growFlacTags(content)
	if content:sub(1, 4) ~= "fLaC" then error("The fixture is not FLAC") end

	---@type tests.FlacBlock[]
	local blocks = {}
	local at = 5
	local audioAt = 0

	while true do
		local first = content:byte(at) or 0
		local length = be24(content, at + 1)
		local body = content:sub(at + 4, at + 3 + length)
		local last = first >= 0x80
		local kind = first % 128

		if kind == 4 then
			local vendorLength = le32(body, 1)
			local countAt = 5 + vendorLength
			local count = le32(body, countAt)
			local entry = "TESTER=fingerprint"
			body = body:sub(1, countAt - 1) .. le32Bytes(count + 1) .. body:sub(countAt + 4)
				.. le32Bytes(#entry) .. entry
		elseif kind == 1 then
			body = body .. string.rep("\0", 100)
		end

		blocks[#blocks + 1] = { kind = kind, last = last, body = body }
		at = at + 4 + length
		if last then
			audioAt = at
			break
		end
	end

	local parts = { "fLaC" }
	for _, block in ipairs(blocks) do
		local length = #block.body
		parts[#parts + 1] = string.char(block.kind + (block.last and 0x80 or 0),
			math.floor(length / 65536) % 256, math.floor(length / 256) % 256, length % 256)
		parts[#parts + 1] = block.body
	end
	parts[#parts + 1] = content:sub(audioAt)

	return table.concat(parts)
end

---@param content string
---@return number 1 based
local function flacAudioAt(content)
	if content:sub(1, 4) ~= "fLaC" then error("The fixture is not FLAC") end

	local at = 5
	while true do
		local first = content:byte(at) or 0
		local length = be24(content, at + 1)
		at = at + 4 + length
		if first >= 0x80 then return at end
	end
end

-- ────────────────────────────────────────────────────────────────
-- WAV
-- ────────────────────────────────────────────────────────────────

--- Puts a LIST/INFO chunk in front of the data chunk.
---@param content string
---@return string
local function insertListChunk(content)
	if content:sub(1, 4) ~= "RIFF" or content:sub(9, 12) ~= "WAVE" then
		error("The fixture is not WAVE")
	end

	local at = 13
	while at + 7 <= #content do
		local id = content:sub(at, at + 3)
		local length = le32(content, at + 4)
		if id == "data" then
			local list = "LIST" .. le32Bytes(20) .. "INFO" .. "INAM" .. le32Bytes(8) .. "Variant\0"
			local riffSize = le32(content, 5) + #list
			return content:sub(1, 4) .. le32Bytes(riffSize) .. content:sub(9, at - 1) .. list
				.. content:sub(at)
		end
		at = at + 8 + length + (length % 2)
	end

	error("The fixture has no data chunk")
end

---@param content string
---@return number 1 based
local function wavDataAt(content)
	local at = 13
	while at + 7 <= #content do
		local id = content:sub(at, at + 3)
		local length = le32(content, at + 4)
		if id == "data" then return at + 8 end
		at = at + 8 + length + (length % 2)
	end

	error("The fixture has no data chunk")
end

-- ────────────────────────────────────────────────────────────────
-- Ogg Opus
-- ────────────────────────────────────────────────────────────────

-- The Ogg checksum, so a page this test writes is a page a decoder would accept.
---@type number[]
local CRC_TABLE = {}
for index = 0, 255 do
	local value = index * 16777216
	for _ = 1, 8 do
		if bit.band(value, 0x80000000) ~= 0 then
			value = bit.bxor(bit.lshift(value, 1), 0x04C11DB7)
		else
			value = bit.lshift(value, 1)
		end
		value = value % 4294967296
	end
	CRC_TABLE[index] = value
end

---@param content string
---@return number
local function oggCrc(content)
	local crc = 0
	for index = 1, #content do
		local slot = bit.band(bit.bxor(bit.rshift(crc, 24), content:byte(index)), 0xFF)
		crc = bit.bxor(bit.lshift(crc, 8), CRC_TABLE[slot]) % 4294967296
	end

	return crc
end

---@param length number
---@param terminate boolean
---@return number[]
local function lacing(length, terminate)
	local values = {}
	while length >= 255 do
		values[#values + 1] = 255
		length = length - 255
	end
	if terminate or length > 0 then values[#values + 1] = length end

	return values
end

---@param serial number
---@param sequence number
---@param headerType number
---@param granule number
---@param segments number[]
---@param body string
---@return string
local function oggPage(serial, sequence, headerType, granule, segments, body)
	local table_ = {}
	for _, value in ipairs(segments) do
		table_[#table_ + 1] = string.char(value)
	end

	local header = "OggS" .. string.char(0, headerType) .. le64Bytes(granule) .. le32Bytes(serial)
		.. le32Bytes(sequence) .. "\0\0\0\0" .. string.char(#segments) .. table.concat(table_)
	local page = header .. body

	return page:sub(1, 22) .. le32Bytes(oggCrc(page)) .. page:sub(27)
end

---@class tests.OggParsed
---@field packets string[]
---@field starts number[] # 1 based offset of each packet's first byte
---@field serial number
---@field lastGranule number

---@param content string
---@return tests.OggParsed
local function parseOgg(content)
	---@type string[]
	local packets = {}
	---@type number[]
	local starts = {}
	---@type string[]
	local pending = {}
	local pendingAt = 0
	local serial = 0
	local lastGranule = 0
	local at = 1

	while at + 26 <= #content do
		if content:sub(at, at + 3) ~= "OggS" then break end

		serial = le32(content, at + 14)
		lastGranule = le32(content, at + 6) + le32(content, at + 10) * 4294967296

		local segments = content:byte(at + 26) or 0
		local lacingTable = content:sub(at + 27, at + 26 + segments)
		local payloadAt = at + 27 + segments

		for index = 1, segments do
			local length = lacingTable:byte(index) or 0
			if #pending == 0 then pendingAt = payloadAt end
			pending[#pending + 1] = content:sub(payloadAt, payloadAt + length - 1)
			payloadAt = payloadAt + length

			if length < 255 then
				packets[#packets + 1] = table.concat(pending)
				starts[#packets] = pendingAt
				pending = {}
			end
		end

		at = payloadAt
	end

	return { packets = packets, starts = starts, serial = serial, lastGranule = lastGranule }
end

---@param packet string
---@return string
local function growOpusComments(packet)
	if packet:sub(1, 8) ~= "OpusTags" then error("The second packet is not OpusTags") end

	local vendorLength = le32(packet, 9)
	local countAt = 13 + vendorLength
	local count = le32(packet, countAt)
	local entry = "TESTER=fingerprint"

	return packet:sub(1, countAt - 1) .. le32Bytes(count + 1) .. packet:sub(countAt + 4)
		.. le32Bytes(#entry) .. entry
end

--- Grows the comment packet and re-pages the stream, so the comment spans two pages and every
--- page after it is renumbered.
---@param content string
---@return string
---@return number commentPages
local function repageWithGrownComments(content)
	local parsed = parseOgg(content)
	if #parsed.packets < 3 then error("The fixture has no audio packets") end

	local grown = growOpusComments(parsed.packets[2])
	local split = 255 * math.max(1, math.floor(#grown / 510))
	if split >= #grown then split = 255 end
	local commentPages = split < #grown and 2 or 1

	local pages = {}
	local sequence = 0

	local head = parsed.packets[1]
	pages[#pages + 1] = oggPage(parsed.serial, sequence, 0x02, 0, lacing(#head, true), head)
	sequence = sequence + 1

	pages[#pages + 1] = oggPage(parsed.serial, sequence, 0, 0, lacing(split, false),
		grown:sub(1, split))
	sequence = sequence + 1

	pages[#pages + 1] = oggPage(parsed.serial, sequence, 0x01, 0, lacing(#grown - split, true),
		grown:sub(split + 1))
	sequence = sequence + 1

	for index = 3, #parsed.packets do
		local flags = 0
		local granule = 0
		if index == #parsed.packets then
			flags = 0x04
			granule = parsed.lastGranule
		end
		local packet = parsed.packets[index]
		pages[#pages + 1] = oggPage(parsed.serial, sequence, flags, granule,
			lacing(#packet, true), packet)
		sequence = sequence + 1
	end

	return table.concat(pages), commentPages
end

---@param content string
---@return number 1 based
local function opusAudioAt(content)
	local parsed = parseOgg(content)
	local at = parsed.starts[3]
	if at == nil then error("The fixture has no audio packet") end

	return at
end

-- ────────────────────────────────────────────────────────────────
-- tests
-- ────────────────────────────────────────────────────────────────

test.it("keeps an MP3 fingerprint when its ID3 tag grows", function()
	local base = fixture("tagged.mp3")
	local variant = growId3Tag(base)

	test.equal(fingerprint(variant), fingerprint(base), "a tag frame and padding do not move the audio")
end)

test.it("keeps a FLAC fingerprint when a comment is added and padding resized", function()
	local base = fixture("tagged.flac")
	local variant = growFlacTags(base)

	test.equal(fingerprint(variant), fingerprint(base), "metadata length does not move the audio")
end)

test.it("keeps a WAV fingerprint when a LIST chunk moves the data", function()
	local base = fixture("tagged.wav")
	local variant = insertListChunk(base)

	test.equal(fingerprint(variant), fingerprint(base), "a chunk before data does not move the audio")
end)

test.it("keeps an Opus fingerprint when the comment packet spans another page", function()
	local base = fixture("tagged.opus")
	local variant, commentPages = repageWithGrownComments(base)

	test.equal(commentPages, 2, "the grown comment is on two pages")
	test.equal(fingerprint(variant), fingerprint(base), "page headers and numbering are not audio")
end)

test.it("keeps an MP3 fingerprint when APEv2 and ID3v1 trailers are added", function()
	local base = fixture("tone.mp3")
	local footer = "APETAGEX" .. le32Bytes(2000) .. le32Bytes(32) .. le32Bytes(0)
		.. le32Bytes(0) .. string.rep("\0", 8)
	local id3v1 = "TAG" .. string.rep("\0", 125)

	test.equal(fingerprint(base .. footer .. id3v1), fingerprint(base),
		"an APEv2 footer before ID3v1 is not audio")
	test.equal(fingerprint(base .. id3v1 .. footer), fingerprint(base),
		"an APEv2 footer after ID3v1 is not audio")
end)

test.it("gives different fingerprints to different audio", function()
	local cases = {
		{ file = "tagged.mp3", at = id3AudioAt, delta = 500 },
		{ file = "tagged.flac", at = flacAudioAt, delta = 500 },
		{ file = "tagged.wav", at = wavDataAt, delta = 500 },
		{ file = "tagged.opus", at = opusAudioAt, delta = 20 },
	}

	for _, case in ipairs(cases) do
		local base = fixture(case.file)
		local variant = mutate(base, case.at(base) + case.delta)

		test.truthy(fingerprint(variant) ~= fingerprint(base),
			case.file .. " changes when its audio does")
	end
end)

test.it("tells apart two tracks whose silence hides a later difference", function()
	local function track(marker)
		local content = string.rep("\0", 1048576) .. string.rep(marker, 256)
			.. string.rep("\0", 16384 + 1024)

		return wavFixture.build({ channels = 1, sampleRate = 8000, bitsPerSample = 16,
			sampleBytes = content })
	end

	local first = track("\1")
	local second = track("\2")

	test.equal(first:sub(1, 1048576), second:sub(1, 1048576), "they start with the same silence")
	test.truthy(fingerprint(first) ~= fingerprint(second), "the difference after the silence is heard")
end)

test.it("gives the same fingerprint to the same bytes at another path", function()
	local content = fixture("tone.flac")

	test.equal(fingerprint(content), fingerprint(content), "the path is not part of the audio")
end)
