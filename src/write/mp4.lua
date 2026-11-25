-- The iTunes metadata of an MP4 movie, rewritten in place. The tag lives in moov/udta/meta/ilst,
-- and a change touches only the items it names: every other box, and every audio byte, is copied
-- through untouched.
local buffer = require("string.buffer")

-- Two to the thirty-second, the step between the halves of a 64 bit integer.
local TWO32 = 4294967296

-- The item each text change writes.
local TEXT_ITEMS = {
	title = "\169nam",
	artist = "\169ART",
	album = "\169alb",
	albumArtist = "aART",
	date = "\169day",
	genre = "\169gen",
	comment = "\169cmt",
}

-- The item each field belongs to. Track and track count share one item, as do a disc's total.
---@type table<string, string>
local ITEM_OF = {
	title = TEXT_ITEMS.title,
	artist = TEXT_ITEMS.artist,
	album = TEXT_ITEMS.album,
	albumArtist = TEXT_ITEMS.albumArtist,
	date = TEXT_ITEMS.date,
	genre = TEXT_ITEMS.genre,
	comment = TEXT_ITEMS.comment,
	track = "trkn",
	trackCount = "trkn",
	disc = "disk",
}

-- New items are added in this order, so the same change always writes the same file.
local ORDER = { "title", "artist", "album", "albumArtist", "track", "trackCount", "disc", "date", "genre", "comment" }

-- The handler a meta box needs before its item list. It says the list holds movie directory tags.
local HDLR = "\0\0\0\33" .. "hdlr" .. "\0\0\0\0" .. "\0\0\0\0" .. "mdir" .. "appl" .. string.rep("\0", 9)

---@class treble.write.mp4.Box
---@field kind string
---@field raw string
---@field body string

---@param data string
---@param at number
---@return number
local function be16(data, at)
	local a, b = data:byte(at, at + 1)
	if a == nil or b == nil then return 0 end

	return a * 256 + b
end

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
local function be64(data, at)
	return be32(data, at) * TWO32 + be32(data, at + 4)
end

---@param value number
---@return string
local function u16(value)
	return string.char(math.floor(value / 256) % 256, value % 256)
end

---@param value number
---@return string
local function u32(value)
	return string.char(
		math.floor(value / 16777216) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256,
		value % 256)
end

---@param value number
---@return string
local function u64(value)
	local high = math.floor(value / TWO32)

	return u32(high) .. u32(value - high * TWO32)
end

--- One box, with a 64 bit size only when it does not fit the usual four bytes.
---@param kind string
---@param body string
---@return string
local function atom(kind, body)
	local size = 8 + #body

	if size <= 0xFFFFFFFF then
		return u32(size) .. kind .. body
	end

	return u32(1) .. kind .. u64(size) .. body
end

--- Splits a sequence of boxes into its children, keeping each one's bytes as they were.
---@param data string
---@return treble.write.mp4.Box[] boxes
---@return string tail # Whatever is left after the last whole box
local function parseBoxes(data)
	---@type treble.write.mp4.Box[]
	local boxes = {}
	local at = 1

	while at + 7 <= #data do
		local size = be32(data, at)
		local kind = data:sub(at + 4, at + 7)
		local header = 8

		if size == 1 then
			if at + 15 > #data then break end
			size = be64(data, at + 8)
			header = 16
		elseif size == 0 then
			-- A box sized zero runs to the end of its parent.
			size = #data - at + 1
		end

		if size < header or at + size - 1 > #data then break end

		boxes[#boxes + 1] = {
			kind = kind,
			raw = data:sub(at, at + size - 1),
			body = data:sub(at + header, at + size - 1),
		}
		at = at + size
	end

	return boxes, data:sub(at)
end

---@param boxes treble.write.mp4.Box[]
---@param kind string
---@return treble.write.mp4.Box?
local function findBox(boxes, kind)
	for _, box in ipairs(boxes) do
		if box.kind == kind then return box end
	end

	return nil
end

--- A `data` box. Type 1 is UTF-8 text, type 0 is the pairs of numbers trkn and disk hold.
---@param kind number
---@param payload string
---@return string
local function dataAtom(kind, payload)
	return atom("data", u32(kind) .. "\0\0\0\0" .. payload)
end

--- The payload of an item's first data box.
---@param item treble.write.mp4.Box
---@return string?
local function itemPayload(item)
	local children = parseBoxes(item.body)

	for _, child in ipairs(children) do
		if child.kind == "data" then
			return child.body:sub(9)
		end
	end

	return nil
end

--- Replaces an item's first data box, keeping any other child the item has.
---@param item treble.write.mp4.Box
---@param kind number
---@param payload string
---@return string
local function rewriteItem(item, kind, payload)
	local children, tail = parseBoxes(item.body)
	local out = buffer.new()
	local replaced = false

	for _, child in ipairs(children) do
		if child.kind == "data" and not replaced then
			out:put(dataAtom(kind, payload))
			replaced = true
		else
			out:put(child.raw)
		end
	end

	if not replaced then out:put(dataAtom(kind, payload)) end
	out:put(tail)

	return atom(item.kind, out:tostring())
end

---@param value any
---@param label string
---@return string? err
local function checkNumber(value, label)
	if type(value) ~= "number" or value < 0 or value > 65535 or value ~= math.floor(value) then
		return label .. " must be a number from 0 to 65535"
	end

	return nil
end

--- The trkn payload with the changed track and total merged into what the item already held.
---@param item treble.write.mp4.Box?
---@param changes treble.TagChanges
---@return string? payload
---@return string? err
local function trknPayload(item, changes)
	local payload = item ~= nil and itemPayload(item) or nil

	local track
	if changes.track ~= nil then
		track = changes.track
	else
		track = payload ~= nil and be16(payload, 3) or nil
	end

	local total
	if changes.trackCount ~= nil then
		total = changes.trackCount ~= false and changes.trackCount or 0
	else
		total = payload ~= nil and be16(payload, 5) or nil
	end

	track = track or 0
	total = total or 0

	---@cast track number
	---@cast total number

	local err = checkNumber(track, "track") or checkNumber(total, "track count")
	if err ~= nil then return nil, err end

	if payload ~= nil then
		-- Keep the two leading bytes and whatever followed the total, as another writer left them.
		return payload:sub(1, 2) .. u16(track) .. u16(total) .. payload:sub(7)
	end

	return "\0\0" .. u16(track) .. u16(total) .. "\0\0"
end

--- The disk payload. A disc's total is not a treble field, so an existing one is kept.
---@param item treble.write.mp4.Box?
---@param disc number
---@return string? payload
---@return string? err
local function diskPayload(item, disc)
	local err = checkNumber(disc, "disc")
	if err ~= nil then return nil, err end

	local payload = item ~= nil and itemPayload(item) or nil

	if payload ~= nil then
		return payload:sub(1, 2) .. u16(disc) .. payload:sub(5)
	end

	return "\0\0" .. u16(disc) .. "\0\0"
end

---@class treble.write.mp4.Plan
---@field write fun(item: treble.write.mp4.Box?): string?, string?

---@param item treble.write.mp4.Box?
---@param value string
---@param kind string
---@return string?
local function writeText(item, value, kind)
	if item ~= nil then return rewriteItem(item, 1, value) end

	return atom(kind, dataAtom(1, value))
end

---@param item treble.write.mp4.Box?
---@param changes treble.TagChanges
---@return string?
---@return string? err
local function writeTrkn(item, changes)
	-- Removing the track number removes the whole item, as treble has nowhere to put a total
	-- without one.
	if changes.track == false then return nil end
	if item == nil and changes.track == nil and changes.trackCount == false then return nil end

	local payload, err = trknPayload(item, changes)
	if payload == nil then return nil, err end

	if item ~= nil then return rewriteItem(item, 0, payload) end

	return atom("trkn", dataAtom(0, payload))
end

---@param item treble.write.mp4.Box?
---@param changes treble.TagChanges
---@return string?
---@return string? err
local function writeDisk(item, changes)
	local disc = changes.disc
	if disc == nil or disc == false then return nil end

	local payload, err = diskPayload(item, disc)
	if payload == nil then return nil, err end

	if item ~= nil then return rewriteItem(item, 0, payload) end

	return atom("disk", dataAtom(0, payload))
end

--- What each changed item will be written as. A plan returns the new item, nil to drop it, or nil
--- and an error.
---@param changes treble.TagChanges
---@return table<string, treble.write.mp4.Plan>
local function plansFor(changes)
	---@type table<string, treble.write.mp4.Plan>
	local plans = {}

	for field, kind in pairs(TEXT_ITEMS) do
		local value = changes[field]
		---@cast value string|false|nil

		if value ~= nil then
			---@cast value string|false
			local text = value
			---@type fun(item: treble.write.mp4.Box?): string?, string?
			local write = function(item)
				if text == false then return nil end

				return writeText(item, text, kind)
			end

			plans[kind] = { write = write }
		end
	end

	-- A genre written as text makes an old gnre number stale, so it goes as well.
	if changes.genre ~= nil then
		---@type fun(item: treble.write.mp4.Box?): string?, string?
		local write = function(item) return nil end
		plans["gnre"] = { write = write }
	end

	if changes.track ~= nil or changes.trackCount ~= nil then
		---@type fun(item: treble.write.mp4.Box?): string?, string?
		local write = function(item) return writeTrkn(item, changes) end
		plans["trkn"] = { write = write }
	end

	if changes.disc ~= nil then
		---@type fun(item: treble.write.mp4.Box?): string?, string?
		local write = function(item) return writeDisk(item, changes) end
		plans["disk"] = { write = write }
	end

	return plans
end

--- The ilst body with the changed items rewritten in place and missing ones appended.
---@param body string
---@param changes treble.TagChanges
---@return string? body
---@return string? err
local function editIlst(body, changes)
	local items, tail = parseBoxes(body)
	local plans = plansFor(changes)
	local out = buffer.new()

	---@type table<string, boolean>
	local handled = {}

	for _, item in ipairs(items) do
		local plan = plans[item.kind]
		if plan == nil then
			out:put(item.raw)
		elseif not handled[item.kind] then
			handled[item.kind] = true
			local raw, err = plan.write(item)
			if err ~= nil then return nil, err end
			if raw ~= nil then out:put(raw) end
		end
	end

	---@type table<string, boolean>
	local appended = {}

	for _, field in ipairs(ORDER) do
		local kind = ITEM_OF[field]
		local plan = plans[kind]
		if plan ~= nil and not handled[kind] and not appended[kind] then
			appended[kind] = true
			local raw, err = plan.write(nil)
			if err ~= nil then return nil, err end
			if raw ~= nil then out:put(raw) end
		end
	end

	out:put(tail)

	return out:tostring()
end

--- The meta body with its item list changed. The four version and flags bytes stay, and the handler
--- goes before the list because that is where the reader looks for it.
---@param body string
---@param changes treble.TagChanges
---@return string? body
---@return string? err
local function editMeta(body, changes)
	local prefix = body:sub(1, 4)
	local children, tail = parseBoxes(body:sub(5))
	local hdlr = findBox(children, "hdlr")
	local ilst = findBox(children, "ilst")

	local ilstBody, err = editIlst(ilst ~= nil and ilst.body or "", changes)
	if ilstBody == nil then return nil, err end

	local out = buffer.new()
	local wroteHdlr = false
	local wroteIlst = false

	for _, child in ipairs(children) do
		if child.kind == "ilst" then
			if not wroteIlst then
				if not wroteHdlr then
					out:put(hdlr ~= nil and hdlr.raw or HDLR)
					wroteHdlr = true
				end
				out:put(atom("ilst", ilstBody))
				wroteIlst = true
			else
				out:put(child.raw)
			end
		elseif child.kind == "hdlr" then
			-- A handler that came after the list already went before it.
			if not wroteIlst then
				out:put(child.raw)
				wroteHdlr = true
			end
		else
			out:put(child.raw)
		end
	end

	if not wroteIlst then
		if not wroteHdlr then out:put(hdlr ~= nil and hdlr.raw or HDLR) end
		out:put(atom("ilst", ilstBody))
	end

	out:put(tail)

	return prefix .. out:tostring()
end

--- The udta body with its meta box changed, making one when the file has no tag yet.
---@param body string
---@param changes treble.TagChanges
---@return string? body
---@return string? err
local function editUdta(body, changes)
	local children, tail = parseBoxes(body)
	local meta = findBox(children, "meta")
	local out = buffer.new()

	if meta ~= nil then
		local metaBody, err = editMeta(meta.body, changes)
		if metaBody == nil then return nil, err end

		local wrote = false
		for _, child in ipairs(children) do
			if child.kind == "meta" then
				if not wrote then
					out:put(atom("meta", metaBody))
					wrote = true
				else
					out:put(child.raw)
				end
			else
				out:put(child.raw)
			end
		end
	else
		for _, child in ipairs(children) do out:put(child.raw) end

		local ilstBody, err = editIlst("", changes)
		if ilstBody == nil then return nil, err end
		out:put(atom("meta", "\0\0\0\0" .. HDLR .. atom("ilst", ilstBody)))
	end

	out:put(tail)

	return out:tostring()
end

--- The moov body with its udta changed, making one when the file has no tag yet.
---@param body string
---@param changes treble.TagChanges
---@return string? body
---@return string? err
local function editMoov(body, changes)
	local children, tail = parseBoxes(body)
	local udta = findBox(children, "udta")
	local out = buffer.new()

	if udta ~= nil then
		local udtaBody, err = editUdta(udta.body, changes)
		if udtaBody == nil then return nil, err end

		local wrote = false
		for _, child in ipairs(children) do
			if child.kind == "udta" then
				if not wrote then
					out:put(atom("udta", udtaBody))
					wrote = true
				else
					out:put(child.raw)
				end
			else
				out:put(child.raw)
			end
		end
	else
		for _, child in ipairs(children) do out:put(child.raw) end

		local ilstBody, err = editIlst("", changes)
		if ilstBody == nil then return nil, err end
		out:put(atom("udta", atom("meta", "\0\0\0\0" .. HDLR .. atom("ilst", ilstBody))))
	end

	out:put(tail)

	return out:tostring()
end

--- Adds a shift to every entry of an stco or co64 table.
---@param body string
---@param shift number
---@param wide boolean # co64 holds eight byte offsets
---@return string? body
---@return string? err
local function shiftChunks(body, shift, wide)
	local count = be32(body, 5)
	local step = wide and 8 or 4
	local first = 9
	local after = first + count * step

	if after - 1 > #body then
		return nil, "truncated chunk offset table"
	end

	local out = buffer.new()
	out:put(body:sub(1, 8))

	for index = 0, count - 1 do
		local at = first + index * step
		local value = wide and be64(body, at) or be32(body, at)
		local moved = value + shift

		if moved < 0 then
			return nil, "chunk offset moved before the start of the file"
		end

		if not wide and moved > 0xFFFFFFFF then
			return nil, "chunk offset does not fit in a 32 bit stco entry"
		end

		out:put(wide and u64(moved) or u32(moved))
	end

	out:put(body:sub(after))

	return out:tostring()
end

-- Only these boxes are walked when looking for the sample tables.
local CONTAINERS = { trak = true, mdia = true, minf = true, stbl = true }

--- Rewrites every chunk offset below a set of boxes, which is what moving moov past them needs.
---@param body string
---@param shift number
---@param insideStbl boolean
---@return string? body
---@return string? err
local function shiftTree(body, shift, insideStbl)
	local children, tail = parseBoxes(body)
	local out = buffer.new()

	for _, child in ipairs(children) do
		local rewritten = nil

		if insideStbl and child.kind == "stco" then
			local chunkBody, err = shiftChunks(child.body, shift, false)
			if chunkBody == nil then return nil, err end
			rewritten = atom("stco", chunkBody)
		elseif insideStbl and child.kind == "co64" then
			local chunkBody, err = shiftChunks(child.body, shift, true)
			if chunkBody == nil then return nil, err end
			rewritten = atom("co64", chunkBody)
		elseif CONTAINERS[child.kind] then
			local treeBody, err = shiftTree(child.body, shift, insideStbl or child.kind == "stbl")
			if treeBody == nil then return nil, err end
			rewritten = atom(child.kind, treeBody)
		end

		out:put(rewritten ~= nil and rewritten or child.raw)
	end

	out:put(tail)

	return out:tostring()
end

--- Rewrites the iTunes tags of an MP4 file, keeping every other byte and the audio in place.
---@param data string
---@param changes treble.TagChanges
---@return string? data
---@return string? err
local function write(data, changes)
	local boxes, tail = parseBoxes(data)

	local moov = nil
	local moovStart, mdatStart = nil, nil
	local at = 1

	for _, box in ipairs(boxes) do
		if box.kind == "moov" and moov == nil then
			moov = box
			moovStart = at
		elseif box.kind == "mdat" and mdatStart == nil then
			mdatStart = at
		end

		at = at + #box.raw
	end

	if moov == nil then return nil, "MP4 file has no moov atom" end

	local moovBody, err = editMoov(moov.body, changes)
	if moovBody == nil then return nil, err end

	local newMoov = atom("moov", moovBody)
	local delta = #newMoov - #moov.raw

	-- When moov comes first, growing it moves every sample in mdat.
	if delta ~= 0 and mdatStart ~= nil and moovStart < mdatStart then
		moovBody, err = shiftTree(moovBody, delta, false)
		if moovBody == nil then return nil, err end
		newMoov = atom("moov", moovBody)
	end

	local out = buffer.new()
	for _, box in ipairs(boxes) do
		out:put(box == moov and newMoov or box.raw)
	end
	out:put(tail)

	return out:tostring()
end

return write
