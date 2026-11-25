-- FLAC keeps its tags in a VORBIS_COMMENT metadata block. The block is rebuilt with the changes and
-- every other block and the audio frames are copied as they are; a file without the block gets one
-- after STREAMINFO. An ID3v2 tag some taggers put before "fLaC" is kept in front.
local buffer = require("string.buffer")
local vorbis = require("treble.write.vorbis")

local STREAMINFO = 0
local VORBIS_COMMENT = 4
local MAX_BLOCK = 16777215

---@param data string
---@param at number
local function be24(data, at)
	local a, b, c = string.byte(data, at, at + 2)
	return a * 65536 + b * 256 + c
end

---@param out string.buffer
---@param kind number
---@param last boolean
---@param body string
local function putBlock(out, kind, last, body)
	local length = #body
	out:put(string.char(kind + (last and 128 or 0), math.floor(length / 65536), math.floor(length / 256) % 256, length % 256))
	out:put(body)
end

--- Where "fLaC" starts, after any ID3v2 tag in front of it.
---@param data string
---@return number?
local function markerAt(data)
	local at = 1
	if string.sub(data, 1, 3) == "ID3" and #data >= 10 then
		local a, b, c, d = string.byte(data, 7, 10)
		local footer = string.byte(data, 6) % 32 >= 16
		at = 11 + a * 2097152 + b * 16384 + c * 128 + d + (footer and 10 or 0)
	end
	if string.sub(data, at, at + 3) ~= "fLaC" then return nil end
	return at
end

---@param data string
---@param changes treble.TagChanges
---@return string? data
---@return string? err
return function(data, changes)
	local marker = markerAt(data)
	if marker == nil then return nil, "not a FLAC file" end

	---@type { kind: number, body: string }[]
	local blocks = {}
	local at = marker + 4
	while true do
		if at + 4 > #data + 1 then return nil, "metadata is cut short" end
		local header = string.byte(data, at)
		local length = be24(data, at + 1)
		local bodyAt = at + 4
		if bodyAt + length > #data + 1 then return nil, "metadata is cut short" end
		blocks[#blocks + 1] = { kind = header % 128, body = string.sub(data, bodyAt, bodyAt + length - 1) }
		at = bodyAt + length
		if header >= 128 then break end
	end
	if blocks[1].kind ~= STREAMINFO then return nil, "STREAMINFO is not the first block" end

	local found = false
	for _, block in ipairs(blocks) do
		if block.kind == VORBIS_COMMENT then
			local body, err = vorbis.rewrite(block.body, 1, changes)
			if body == nil then return nil, err end
			block.body = body
			found = true
			break
		end
	end
	if not found then
		local out = buffer.new()
		vorbis.put(out, { vendor = "treble", list = vorbis.apply({}, changes), rest = "" })
		table.insert(blocks, 2, { kind = VORBIS_COMMENT, body = out:tostring() })
	end

	local out = buffer.new(#data + 4096)
	out:put(string.sub(data, 1, marker + 3))
	for i, block in ipairs(blocks) do
		if #block.body > MAX_BLOCK then return nil, "tags are too large for a FLAC block" end
		putBlock(out, block.kind, i == #blocks, block.body)
	end
	out:put(string.sub(data, at))
	return out:tostring()
end
