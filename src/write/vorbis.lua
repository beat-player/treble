-- The "KEY=value" list Ogg and FLAC keep their tags in, read from its packed form and written back
-- with some fields changed. Every comment a change does not name is kept as it was, in its place;
-- a changed field takes the place of the first comment it replaces, and a field the list did not
-- have goes at the end.
local buffer = require("string.buffer")

local vorbis = {}

-- New fields are added in this order, so the same change always writes the same file.
local ORDER = { "title", "artist", "album", "albumArtist", "track", "trackCount", "disc", "date", "genre", "comment" }

-- The keys each field is read from (see Tags.fromVorbisComments). Writing a field removes all of
-- them and writes the first.
---@type table<string, string[]>
local KEYS = {
	title = { "TITLE" },
	artist = { "ARTIST" },
	album = { "ALBUM" },
	albumArtist = { "ALBUMARTIST", "ALBUM ARTIST" },
	track = { "TRACKNUMBER" },
	trackCount = { "TRACKTOTAL", "TOTALTRACKS" },
	disc = { "DISCNUMBER" },
	date = { "DATE", "YEAR" },
	genre = { "GENRE" },
	comment = { "COMMENT", "DESCRIPTION" }
}

---@type table<string, string>
local FIELD_OF = {}
for field, keys in pairs(KEYS) do
	for _, key in ipairs(keys) do FIELD_OF[key] = field end
end

---@param data string
---@param at number # One based
local function le32(data, at)
	local a, b, c, d = string.byte(data, at, at + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end

---@param out string.buffer
---@param value number
local function putLe32(out, value)
	out:put(string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256))
end

---@class treble.write.Comments
---@field vendor string
---@field list string[]
---@field rest string # Whatever follows the list in the packet, kept as it is

--- Reads a packed comment list starting at `at`.
---@param data string
---@param at number # One based
---@return treble.write.Comments? comments
---@return string? err
function vorbis.parse(data, at)
	if at + 8 > #data + 1 then return nil, "comment block is cut short" end
	local vendorLength = le32(data, at)
	at = at + 4
	if at + vendorLength + 4 > #data + 1 then return nil, "comment block is cut short" end
	local vendor = string.sub(data, at, at + vendorLength - 1)
	at = at + vendorLength
	local count = le32(data, at)
	at = at + 4
	local list = {}
	for i = 1, count do
		if at + 4 > #data + 1 then return nil, "comment block is cut short" end
		local length = le32(data, at)
		at = at + 4
		if at + length > #data + 1 then return nil, "comment block is cut short" end
		list[i] = string.sub(data, at, at + length - 1)
		at = at + length
	end
	return { vendor = vendor, list = list, rest = string.sub(data, at) }
end

---@param value string|number
---@return string
local function textOf(value)
	if type(value) == "number" then return string.format("%d", value) end
	return value
end

--- The value a changed field is written as, or nil when it is removed. A track number keeps the
--- total its comment carried after a slash unless the total is changed as well.
---@param field string
---@param changes treble.TagChanges
---@param old string? # The field's first comment value before the change
---@return string?
local function valueOf(field, changes, old)
	local value = changes[field]
	if value == false then return nil end
	if field == "track" and changes.trackCount == nil and old ~= nil then
		local total = old:match("/%s*(%d+)%s*$")
		if total ~= nil then return textOf(value) .. "/" .. total end
	end
	return textOf(value)
end

--- The list with the changes applied. New fields go before the first picture: a picture is a
--- comment too, and a reader that only looks at the start of a file finds text tags that come
--- before it.
---@param list string[]
---@param changes treble.TagChanges
---@return string[]
function vorbis.apply(list, changes)
	local out = {}
	---@type table<string, boolean>
	local written = {}
	local pictureAt = nil
	for _, comment in ipairs(list) do
		local equals = string.find(comment, "=", 1, true)
		local key = equals ~= nil and string.upper(string.sub(comment, 1, equals - 1)) or nil
		local field = key ~= nil and FIELD_OF[key] or nil
		if field == nil or changes[field] == nil then
			if key == "METADATA_BLOCK_PICTURE" and pictureAt == nil then pictureAt = #out + 1 end
			out[#out + 1] = comment
		elseif not written[field] then
			written[field] = true
			local value = valueOf(field, changes, string.sub(comment, equals + 1))
			if value ~= nil then out[#out + 1] = KEYS[field][1] .. "=" .. value end
		end
	end
	for _, field in ipairs(ORDER) do
		if not written[field] and changes[field] ~= nil and changes[field] ~= false then
			local comment = KEYS[field][1] .. "=" .. assert(valueOf(field, changes, nil))
			if pictureAt ~= nil then
				table.insert(out, pictureAt, comment)
				pictureAt = pictureAt + 1
			else
				out[#out + 1] = comment
			end
		end
	end
	return out
end

--- Packs a comment list the way `parse` reads it.
---@param out string.buffer
---@param comments treble.write.Comments
function vorbis.put(out, comments)
	putLe32(out, #comments.vendor)
	out:put(comments.vendor)
	putLe32(out, #comments.list)
	for _, comment in ipairs(comments.list) do
		putLe32(out, #comment)
		out:put(comment)
	end
	out:put(comments.rest)
end

--- Reads, changes and packs a comment list in one go.
---@param data string
---@param at number
---@param changes treble.TagChanges
---@return string? packed
---@return string? err
function vorbis.rewrite(data, at, changes)
	local comments, err = vorbis.parse(data, at)
	if comments == nil then return nil, err end
	comments.list = vorbis.apply(comments.list, changes)
	local out = buffer.new()
	vorbis.put(out, comments)
	return out:tostring()
end

return vorbis
