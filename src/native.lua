local ffi = require("ffi")

--- Finds a shared library the way require would, by walking package.cpath.
---@param name string
---@return string? path
local function findLibrary(name)
	local modulePath = name:gsub("%.", "/")

	for template in package.cpath:gmatch("[^;]+") do
		local path = template:gsub("%?", modulePath)
		local file = io.open(path, "rb")
		if file then
			file:close()
			return path
		end
	end

	return nil
end

--- The decoders build.lua compiles: dr_mp3, dr_flac, libogg, libopus and
--- libopusfile in one library.
---@class treble.native
---@field path string
---@field lib ffi.namespace*
local native = {}

local name = "treble.decoders"
local path = findLibrary(name)
local lib

if path ~= nil then
	lib = ffi.load(path)
else
	-- A compiled lde binary embeds the library in the executable and remaps
	-- ffi.load by its module name, so there is no file on disk to find first.
	local ok
	ok, lib = pcall(ffi.load, name)
	if not ok then
		ok, lib = pcall(ffi.load, "decoders")
	end
	if not ok then
		error("The native decoders are missing. Run `lde sync` to build them from build.lua. "
			.. tostring(lib))
	end
	path = name
end

native.path = path
native.lib = lib

return native
