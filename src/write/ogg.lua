-- Ogg Opus and Ogg Vorbis keep their tags in the stream's second packet ("OpusTags", or Vorbis's
-- comment header). The header packets after the first are taken out of their pages, the comment
-- packet is rebuilt, and they are laid out in new pages. When that takes as many pages as before,
-- the rest of the file is copied as it is; otherwise the stream's later pages are numbered again,
-- which changes their checksums too. The audio packets themselves are never touched.
local bit = require("bit")
local ffi = require("ffi")
local buffer = require("string.buffer")
local vorbis = require("treble.write.vorbis")

local band, bxor, lshift, rshift = bit.band, bit.bxor, bit.lshift, bit.rshift

local CONTINUED = 1
-- A page header before its lacing values.
local HEADER = 27
-- The granule position of a page on which no packet ends.
local NO_GRANULE = string.rep("\255", 8)
local ZERO_GRANULE = string.rep("\0", 8)

-- Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, starting from zero.
local CRC = ffi.new("uint32_t[256]")
for i = 0, 255 do
	local r = lshift(i, 24)
	for _ = 1, 8 do
		if band(r, 0x80000000) ~= 0 then
			r = bxor(lshift(r, 1), 0x04C11DB7)
		else
			r = lshift(r, 1)
		end
	end
	CRC[i] = r
end

--- The checksum of a page whose checksum field is zero.
---@param bytes ffi.cdata* # uint8_t*
---@param length number
---@return number
local function crcOf(bytes, length)
	local crc = 0
	for i = 0, length - 1 do
		crc = bxor(lshift(crc, 8), CRC[bxor(rshift(crc, 24), bytes[i])])
	end
	return crc
end

---@param value number
---@return string
local function le32(value)
	return string.char(band(value, 255), band(rshift(value, 8), 255), band(rshift(value, 16), 255), band(rshift(value, 24), 255))
end

---@class treble.write.OggPage
---@field at number # One based offset of "OggS"
---@field length number # The whole page
---@field flags number
---@field serial string # Four raw bytes
---@field lacing number[]
---@field bodyAt number

---@param data string
---@param at number
---@return treble.write.OggPage? page
---@return string? err
local function pageAt(data, at)
	if string.sub(data, at, at + 3) ~= "OggS" then return nil, "lost the Ogg page sync" end
	if at + HEADER > #data + 1 then return nil, "page is cut short" end
	local count = string.byte(data, at + 26)
	local lacing = { string.byte(data, at + HEADER, at + HEADER + count - 1) }
	local size = 0
	for i = 1, count do size = size + lacing[i] end
	local bodyAt = at + HEADER + count
	if bodyAt + size > #data + 1 then return nil, "page is cut short" end
	return {
		at = at,
		length = HEADER + count + size,
		flags = string.byte(data, at + 5),
		serial = string.sub(data, at + 14, at + 17),
		lacing = lacing,
		bodyAt = bodyAt
	}
end

--- Writes one page; its checksum is filled in afterwards by `seal`.
---@param out string.buffer
---@param flags number
---@param granule string
---@param serial string
---@param sequence number
---@param lacing number[]
---@param body string
local function putPage(out, flags, granule, serial, sequence, lacing, body)
	out:put("OggS\0", string.char(flags), granule, serial, le32(sequence), "\0\0\0\0", string.char(#lacing))
	for i = 1, #lacing do out:put(string.char(lacing[i])) end
	out:put(body)
end

--- Fills in the checksum of the page `start` bytes into `out`, which runs to its end.
---@param out string.buffer
---@param start number # Zero based
local function seal(out, start)
	local pointer, length = out:ref()
	local page = ffi.cast("uint8_t*", pointer) + start
	local crc = crcOf(page, length - start)
	page[22] = band(crc, 255)
	page[23] = band(rshift(crc, 8), 255)
	page[24] = band(rshift(crc, 16), 255)
	page[25] = band(rshift(crc, 24), 255)
end

--- Lays packets out in pages the way an encoder does: up to 255 lacing values a page, a page that
--- starts inside a packet marked as continued.
---@param out string.buffer
---@param packets string[]
---@param serial string
---@param sequence number # Of the first page
---@return number next # The sequence number after the last page written
local function paginate(out, packets, serial, sequence)
	-- The lacing values and body bytes of the page being filled.
	local lacing, body = {}, buffer.new()
	local continued, ended = false, false
	local function flush(nextContinued)
		local start = #out
		putPage(out, continued and CONTINUED or 0, ended and ZERO_GRANULE or NO_GRANULE, serial, sequence, lacing, body:tostring())
		seal(out, start)
		sequence = sequence + 1
		lacing, continued, ended = {}, nextContinued, false
		body:reset()
	end
	for p, packet in ipairs(packets) do
		local at = 1
		local left = #packet
		while true do
			if #lacing == 255 then flush(true) end
			local size = left >= 255 and 255 or left
			lacing[#lacing + 1] = size
			body:put(string.sub(packet, at, at + size - 1))
			at, left = at + size, left - size
			if size < 255 then break end
		end
		ended = true
		-- Audio starts on a page of its own, so the last header packet ends its page.
		if p == #packets or #lacing == 255 then flush(false) end
	end
	return sequence
end

---@param data string
---@param changes treble.TagChanges
---@return string? data
---@return string? err
return function(data, changes)
	local first, err = pageAt(data, 1)
	if first == nil then return nil, err end
	local id = string.sub(data, first.bodyAt, first.bodyAt + 7)
	local wanted, prefix
	if id == "OpusHead" then
		-- Opus has one more header packet: the tags.
		wanted, prefix = 1, "OpusTags"
	elseif string.sub(id, 1, 7) == "\1vorbis" then
		-- Vorbis has two: the comments, then the codebooks.
		wanted, prefix = 2, "\3vorbis"
	else
		return nil, "not an Ogg Opus or Ogg Vorbis stream"
	end

	-- The header packets after the first, read out of the pages that follow it.
	local packets = {}
	local pending = buffer.new()
	local at = first.at + first.length
	local pages = 1
	while #packets < wanted do
		local page
		page, err = pageAt(data, at)
		if page == nil then return nil, err end
		if page.serial ~= first.serial then return nil, "the stream's headers are interleaved with another stream" end
		local offset = page.bodyAt
		for i = 1, #page.lacing do
			local size = page.lacing[i]
			pending:put(string.sub(data, offset, offset + size - 1))
			offset = offset + size
			if size < 255 then
				packets[#packets + 1] = pending:tostring()
				pending:reset()
				if #packets == wanted and i < #page.lacing then return nil, "audio shares a page with the headers" end
			end
		end
		at = at + page.length
		pages = pages + 1
	end

	local comments = packets[1]
	if string.sub(comments, 1, #prefix) ~= prefix then return nil, "the second packet is not a comment header" end
	local rewritten
	rewritten, err = vorbis.rewrite(comments, #prefix + 1, changes)
	if rewritten == nil then return nil, err end
	packets[1] = prefix .. rewritten

	local out = buffer.new(#data + 4096)
	out:put(string.sub(data, 1, first.length))
	local sequence = paginate(out, packets, first.serial, 1)
	if sequence == pages then
		out:put(string.sub(data, at))
		return out:tostring()
	end

	-- The header took a different number of pages: every later page of this stream moves by as many.
	while at <= #data do
		local page
		page, err = pageAt(data, at)
		if page == nil then return nil, err end
		local start = #out
		out:put(string.sub(data, at, at + page.length - 1))
		if page.serial == first.serial then
			local pointer = ffi.cast("uint8_t*", (out:ref())) + start
			local number = le32(sequence)
			for i = 0, 3 do pointer[18 + i] = string.byte(number, i + 1) end
			for i = 22, 25 do pointer[i] = 0 end
			seal(out, start)
			sequence = sequence + 1
		end
		at = at + page.length
	end
	return out:tostring()
end
