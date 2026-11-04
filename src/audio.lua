-- Format dispatch: opens whatever the content actually turns out to be.
local ffi = require("ffi")
local Wav = require("treble.formats.wav")
local Flac = require("treble.formats.flac")
local Mp3 = require("treble.formats.mp3")
local Opus = require("treble.formats.opus")
local Inspect = require("treble.inspect")

-- Enough to hold the magic bytes and, for opus, the header packet.
local SNIFF_SIZE = 64

---@class treble.audio.Format
---@field name string
---@field isValid fun(content: string): boolean
---@field fromPath fun(path: string): treble.Source?, string?
---@field fromMemory fun(pointer: ffi.cdata*, size: number): treble.Source?, string?

---@type treble.audio.Format[]
local FORMATS = {
	{ name = "WAV", isValid = Wav.isValid, fromPath = Wav.fromPath, fromMemory = Wav.fromMemory },
	{ name = "FLAC", isValid = Flac.isValid, fromPath = Flac.fromPath, fromMemory = Flac.fromMemory },
	{ name = "MP3", isValid = Mp3.isValid, fromPath = Mp3.fromPath, fromMemory = Mp3.fromMemory },
	{ name = "Opus", isValid = Opus.isValid, fromPath = Opus.fromPath, fromMemory = Opus.fromMemory },
}

---@param content string
---@return treble.audio.Format? format
local function detect(content)
	for _, format in ipairs(FORMATS) do
		if format.isValid(content) then
			return format
		end
	end

	return nil
end

---@class treble.audio
---@field inspect fun(path: string): treble.audio.Inspect?, string?
local audio = {}

--- Opens a file as a source, picking the decoder from its first bytes.
---@param path string
---@return treble.Source? source
---@return string? err
function audio.fromPath(path)
	local file, openErr = io.open(path, "rb")
	if not file then
		return nil, "Failed to open audio file: " .. openErr
	end

	local head = file:read(SNIFF_SIZE) or ""
	file:close()

	local format = detect(head)
	if format == nil then
		return nil, "Unsupported audio format: " .. path
	end

	return format.fromPath(path)
end

--- Opens memory as a source. The memory must stay alive until the source is closed.
---@param pointer ffi.cdata*
---@param size number
---@return treble.Source? source
---@return string? err
function audio.fromMemory(pointer, size)
	local head = ffi.string(ffi.cast("const char*", pointer), math.min(size, SNIFF_SIZE))

	local format = detect(head)
	if format == nil then
		return nil, "Unsupported audio format"
	end

	return format.fromMemory(pointer, size)
end

--- Reads only what a tag reader needs, so a library scan costs one header per
--- file rather than a decode.
---@param path string
---@return treble.Tags? tags
---@return string? err
function audio.tags(path)
	local source, err = audio.fromPath(path)
	if source == nil then
		return nil, err
	end

	local tags = source.tags
	source:close()

	if tags == nil then
		return nil, "No tags in " .. path
	end

	return tags
end

---@class treble.audio.Probe
---@field format string
---@field sampleRate number
---@field channels number
---@field frameCount number # 0 when the file does not state it
---@field duration number # Seconds, 0 when the length is unknown
---@field tags treble.Tags?

--- What a file is, without reading its audio.
---@param path string
---@return treble.audio.Probe? probe
---@return string? err
function audio.probe(path)
	local source, err = audio.fromPath(path)
	if source == nil then
		return nil, err
	end

	local name = ""
	local file = io.open(path, "rb")
	if file ~= nil then
		local head = file:read(SNIFF_SIZE) or ""
		file:close()

		local detected = detect(head)
		name = detected ~= nil and detected.name or ""
	end

	---@type treble.audio.Probe
	local probe = {
		format = name,
		sampleRate = source.sampleRate,
		channels = source.channels,
		frameCount = source.frameCount,
		duration = source.frameCount > 0 and source.frameCount / source.sampleRate or 0,
		tags = source.tags,
	}

	source:close()

	return probe
end

---@param content string
function audio.isValid(content)
	return detect(string.sub(content, 1, SNIFF_SIZE)) ~= nil
end

audio.inspect = Inspect.inspect

return audio
