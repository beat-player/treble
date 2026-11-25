-- The ID3v2 tag in front of an MP3, rewritten in place. Frames a change does not name are kept as
-- they were, and the tag is always written as v2.4 without unsynchronisation, so a reader never has
-- to deal with the version the file happened to carry.
local bit = require("bit")
local buffer = require("string.buffer")

-- The largest value a synchsafe integer can hold.
local SYNCHSAFE_LIMIT = 0x10000000

-- The text frame each change writes.
local TEXT_FRAMES = {
	title = "TIT2",
	artist = "TPE1",
	album = "TALB",
	albumArtist = "TPE2",
	genre = "TCON",
}

-- New frames are added in this order, so the same change always writes the same tag.
local TEXT_ORDER = { "title", "artist", "album", "albumArtist", "genre" }

---@class treble.write.id3.Frame
---@field id string
---@field status number
---@field format number
---@field body string

---@param data string
---@param at number
---@return number
local function be32(data, at)
	local a, b, c, d = data:byte(at, at + 3)
	if a == nil or b == nil or c == nil or d == nil then return 0 end

	return a * 16777216 + b * 65536 + c * 256 + d
end

---@param data string
---@param at number
---@return number
local function synchsafe(data, at)
	local a, b, c, d = data:byte(at, at + 3)
	if a == nil or b == nil or c == nil or d == nil then return 0 end

	return a * 2097152 + b * 16384 + c * 128 + d
end

---@param out string.buffer
---@param value number
local function putSynchsafe(out, value)
	out:put(string.char(
		math.floor(value / 2097152) % 128,
		math.floor(value / 16384) % 128,
		math.floor(value / 128) % 128,
		value % 128))
end

--- Undoes ID3 unsynchronisation: every stored FF 00 stands for one FF.
---@param raw string
---@return string
local function deunsync(raw)
	return (raw:gsub("\255%z", "\255"))
end

--- The text a frame carries, enough to read the numbers back out of it. UTF-16 text is kept as its
--- non-zero bytes: track and disc numbers are digits, and their zeros would only get in the way.
---@param payload string
---@return string
local function frameText(payload)
	local encoding = payload:byte(1) or 0
	local text = payload:sub(2)

	if encoding == 1 or encoding == 2 then
		text = text:gsub("%z", "")
	end

	return (text:gsub("%z+$", ""))
end

---@param value string
---@return string body
local function textBody(value)
	return string.char(3) .. value
end

---@param value number
---@return string
local function numberText(value)
	return string.format("%d", math.floor(value))
end

---@param text string
---@return number? current
---@return number? total
local function parseNumber(text)
	local current, total = text:match("(%d+)%s*/%s*(%d+)")
	if current ~= nil then
		return tonumber(current), tonumber(total)
	end

	local only = text:match("(%d+)")
	return only ~= nil and tonumber(only) or nil, nil
end

---@param frames treble.write.id3.Frame[]
---@param id string
---@return treble.write.id3.Frame?
local function firstFrame(frames, id)
	for _, frame in ipairs(frames) do
		if frame.id == id then return frame end
	end

	return nil
end

--- Replaces the first frame with this ID in place, drops the rest, and appends one when there was
--- none. A nil body removes every frame with the ID.
---@param frames treble.write.id3.Frame[]
---@param id string
---@param body string?
---@param keepStatus boolean?
---@return treble.write.id3.Frame[]
local function replaceFrame(frames, id, body, keepStatus)
	local out = {}
	local replaced = false

	for _, frame in ipairs(frames) do
		if frame.id == id then
			if not replaced and body ~= nil then
				out[#out + 1] = {
					id = id,
					status = keepStatus and frame.status or 0,
					format = 0,
					body = body,
				}
				replaced = true
			end
		else
			out[#out + 1] = frame
		end
	end

	if body ~= nil and not replaced then
		out[#out + 1] = { id = id, status = 0, format = 0, body = body }
	end

	return out
end

--- Whether a comment frame has the empty description treble writes and replaces.
---@param payload string
---@return boolean
local function commentIsEmpty(payload)
	if #payload < 4 then return false end

	local encoding = payload:byte(1) or 0
	local description = payload:sub(5)

	if encoding == 1 or encoding == 2 then
		return description:sub(1, 2) == "\0\0"
	end

	return description:byte(1) == 0
end

---@param value string
---@return string
local function commentBody(value)
	return string.char(3) .. "eng" .. "\0" .. value
end

---@param frames treble.write.id3.Frame[]
---@param value string|false
---@return treble.write.id3.Frame[]
local function applyComment(frames, value)
	local out = {}
	local replaced = false

	for _, frame in ipairs(frames) do
		if frame.id == "COMM" and commentIsEmpty(frame.body) then
			if not replaced then
				if value ~= false then
					out[#out + 1] = {
						id = "COMM",
						status = frame.status,
						format = 0,
						body = commentBody(value),
					}
				end
				replaced = true
			end
		else
			out[#out + 1] = frame
		end
	end

	if value ~= false and not replaced then
		out[#out + 1] = { id = "COMM", status = 0, format = 0, body = commentBody(value) }
	end

	return out
end

---@param frames treble.write.id3.Frame[]
---@param changes treble.TagChanges
---@return treble.write.id3.Frame[]
local function applyTrack(frames, changes)
	if changes.track == nil and changes.trackCount == nil then return frames end

	-- A track number with no total is a TRCK frame without a slash.
	if changes.track == false then
		return replaceFrame(frames, "TRCK", nil)
	end

	local existing = firstFrame(frames, "TRCK")
	local current, total = nil, nil
	if existing ~= nil then
		current, total = parseNumber(frameText(existing.body))
	end

	local track = changes.track
	if track == nil then track = current end

	local count
	if changes.trackCount == nil then
		count = total
	elseif changes.trackCount == false then
		count = nil
	else
		count = changes.trackCount
	end

	if track == nil and count == nil then
		return replaceFrame(frames, "TRCK", nil)
	end

	local text
	if count ~= nil then
		text = numberText(track or 0) .. "/" .. numberText(count)
	else
		text = numberText(track or 0)
	end

	return replaceFrame(frames, "TRCK", textBody(text), true)
end

---@param frames treble.write.id3.Frame[]
---@param changes treble.TagChanges
---@return treble.write.id3.Frame[]
local function applyDisc(frames, changes)
	local disc = changes.disc
	if disc == nil then return frames end
	if disc == false then return replaceFrame(frames, "TPOS", nil) end

	local existing = firstFrame(frames, "TPOS")
	local _, total = nil, nil
	if existing ~= nil then
		_, total = parseNumber(frameText(existing.body))
	end

	local text = numberText(disc) .. (total ~= nil and "/" .. numberText(total) or "")

	return replaceFrame(frames, "TPOS", textBody(text), true)
end

--- v2.3 splits the date over TYER and TDAT. A changed date replaces both with the v2.4 TDRC frame.
---@param frames treble.write.id3.Frame[]
---@param changes treble.TagChanges
---@return treble.write.id3.Frame[]
local function applyDate(frames, changes)
	local value = changes.date
	if value == nil then return frames end

	frames = replaceFrame(frames, "TDRC", nil)
	frames = replaceFrame(frames, "TYER", nil)
	frames = replaceFrame(frames, "TDAT", nil)

	if value ~= false then
		frames[#frames + 1] = { id = "TDRC", status = 0, format = 0, body = textBody(value) }
	end

	return frames
end

---@class treble.write.id3.Parsed
---@field frames treble.write.id3.Frame[]
---@field audioAt number # 1 based offset of the first byte after the tag

--- Reads the frames of the tag at the front of the file, undoing unsynchronisation and skipping
--- the extended header. The frames come back in the shape a v2.4 header writes.
---@param data string
---@return treble.write.id3.Parsed? parsed
---@return string? err
local function parseTag(data)
	local major = data:byte(4) or 0

	if major == 2 then
		return nil, "ID3v2.2 tags can't be written"
	end

	if major ~= 3 and major ~= 4 then
		return nil, "ID3v2." .. major .. " tags can't be written"
	end

	local flags = data:byte(6) or 0
	local size = synchsafe(data, 7)
	local footer = major == 4 and bit.band(flags, 0x10) ~= 0 and 10 or 0

	local audioAt = 11 + size + footer
	if audioAt > #data + 1 then audioAt = #data + 1 end

	local body = data:sub(11, math.min(#data, 10 + size))
	if major == 3 and bit.band(flags, 0x80) ~= 0 then
		body = deunsync(body)
	end

	-- v2.4 unsynchronises whole frames. The header flag says every frame in the tag was escaped,
	-- whether or not the frame also carries the flag of its own.
	local tagUnsync = major == 4 and bit.band(flags, 0x80) ~= 0

	local at = 1

	if bit.band(flags, 0x40) ~= 0 then
		-- The extended header is dropped, so its size only says where the frames begin.
		if major == 4 then
			at = 1 + synchsafe(body, 1)
		else
			at = 1 + 4 + be32(body, 1)
		end
	end

	---@type treble.write.id3.Frame[]
	local frames = {}

	while at + 9 <= #body do
		local id = body:sub(at, at + 3)

		-- Padding starts with a zero byte, and anything that is not a frame ID ends the tag.
		if body:byte(at) == 0 or id:match("^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]$") == nil then
			break
		end

		local frameSize = major == 4 and synchsafe(body, at + 4) or be32(body, at + 4)
		if frameSize <= 0 or at + 9 + frameSize > #body then break end

		local status = body:byte(at + 8) or 0
		local format = body:byte(at + 9) or 0
		local payload = body:sub(at + 10, at + 9 + frameSize)

		if major == 4 then
			if bit.band(format, 0x0C) ~= 0 then
				-- A compressed or encrypted frame is kept as it is. Its bytes still need the same
				-- decompressor or key, so the flags that say so stay.
			else
				if bit.band(format, 0x01) ~= 0 then
					-- The data length indicator is not part of the content.
					payload = payload:sub(5)
					format = bit.band(format, 0xFE)
				end

				if bit.band(format, 0x02) ~= 0 or tagUnsync then
					payload = deunsync(payload)
					format = bit.band(format, 0xFD)
				end
			end
		else
			-- v2.3 spells the same format flags differently. Touched frames become v2.4 frames.
			local translated = 0
			if bit.band(format, 0x80) ~= 0 then translated = translated + 0x08 end
			if bit.band(format, 0x40) ~= 0 then translated = translated + 0x04 end
			if bit.band(format, 0x20) ~= 0 then translated = translated + 0x40 end
			format = translated
		end

		frames[#frames + 1] = { id = id, status = status, format = format, body = payload }
		at = at + 10 + frameSize
	end

	return { frames = frames, audioAt = audioAt }
end

--- Serialises the frames as one v2.4 tag followed by the audio.
---@param frames treble.write.id3.Frame[]
---@param audio string
---@return string? data
---@return string? err
local function pack(frames, audio)
	local body = buffer.new()

	for _, frame in ipairs(frames) do
		if #frame.body >= SYNCHSAFE_LIMIT then
			return nil, "ID3 frame " .. frame.id .. " is too large"
		end

		body:put(frame.id)
		putSynchsafe(body, #frame.body)
		body:put(string.char(frame.status, frame.format))
		body:put(frame.body)
	end

	-- The padding keeps the tag from having to grow for a small change later.
	body:put(string.rep("\0", 1024))

	local content = body:tostring()
	if #content >= SYNCHSAFE_LIMIT then
		return nil, "ID3 tag is too large"
	end

	local out = buffer.new()
	out:put("ID3")
	out:put(string.char(4, 0, 0))
	putSynchsafe(out, #content)
	out:put(content)
	out:put(audio)

	return out:tostring()
end

--- Rewrites the ID3v2 tag of an MP3. A file without one gets a new tag in front of its audio.
---@param data string
---@param changes treble.TagChanges
---@return string? data
---@return string? err
local function write(data, changes)
	---@type treble.write.id3.Frame[]
	local frames = {}
	local audioAt = 1

	if data:sub(1, 3) == "ID3" then
		local parsed, err = parseTag(data)
		if parsed == nil then return nil, err end

		frames = parsed.frames
		audioAt = parsed.audioAt
	end

	for _, field in ipairs(TEXT_ORDER) do
		local value = changes[field]
		---@cast value string|false|nil
		if value ~= nil then
			---@cast value string|false
			local id = TEXT_FRAMES[field]
			local body = nil
			if value ~= false then body = textBody(value) end

			frames = replaceFrame(frames, id, body, true)
		end
	end

	frames = applyDate(frames, changes)
	frames = applyTrack(frames, changes)
	frames = applyDisc(frames, changes)

	if changes.comment ~= nil then
		frames = applyComment(frames, changes.comment)
	end

	return pack(frames, data:sub(audioAt))
end

return write
