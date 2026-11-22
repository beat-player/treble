-- Fetches and compiles the C decoders treble plays from.
--
-- The sources come from release tarballs, so the repository carries the recipe
-- rather than a copy of four libraries. lde runs this script again whenever
-- anything under src/ changes, so the extracted sources and the compiled library
-- are cached in the target directory and reused while the recipe stays the same.
local build = require("lde-build")
local bit = require("bit")

-- Bump when the recipe changes in a way the cache key cannot see.
local RECIPE_VERSION = 8

local DR_MP3_VERSION = "mp3-0.7.3"
local DR_FLAC_VERSION = "flac-0.13.3"
local OGG_VERSION = "v1.3.6"
local OPUS_VERSION = "v1.6.1"
local OPUSFILE_VERSION = "v0.12"

-- A directory lde keeps across rebuilds and never bundles. An lde without it gets a dot directory
-- beside the target, which a bundle also skips: a cache in a directory of its own name is a module
-- directory, and every library cached in it, for every target, ships with the app.
local CACHE_DIR = build.cacheDir or "../.treble-native"
local CACHE_NAME = "treble"

local isWindows = jit.os == "Windows"
-- Windows has two toolchains in the wild: mingw, whose linker is GNU ld, and the
-- clang that targets MSVC, which hands its arguments to lld-link or link.exe and
-- rejects both -fPIC and the GNU linker options.
local isMsvc = build.target:find("msvc") ~= nil
local isMac = jit.os == "OSX"
local libraryName = isWindows and "decoders.dll" or "decoders.so"

---@class treble.Vendored
---@field name string
---@field repo string
---@field tag string

---@type treble.Vendored[]
local VENDORED = {
	{ name = "dr_mp3", repo = "mackron/dr_libs", tag = DR_MP3_VERSION },
	{ name = "dr_flac", repo = "mackron/dr_libs", tag = DR_FLAC_VERSION },
	{ name = "ogg", repo = "xiph/ogg", tag = OGG_VERSION },
	{ name = "opus", repo = "xiph/opus", tag = OPUS_VERSION },
	{ name = "opusfile", repo = "xiph/opusfile", tag = OPUSFILE_VERSION },
}

--- Where the extracted release tarball lands.
---@param entry treble.Vendored
---@return string
local function entryDir(entry)
	-- GitHub tarballs extract to <repo>-<tag>, without the v prefix on the tag.
	local root = entry.repo:match("[^/]+$") .. "-" .. entry.tag:gsub("^v", "")

	return CACHE_DIR .. "/" .. entry.name .. "/" .. root
end

-- Sources only opus's encoder needs, which is most of libopus. Leaving them out
-- is what keeps this library small: a shared library exports every global symbol
-- it defines, an exported symbol is a root for dead code elimination, so
-- compiling the encoder in would keep all of it alive. The link runs with
-- --no-undefined and the tests decode real files, so a name that turns out to be
-- needed fails the build instead of shipping a decoder that crashes at load.
local ENCODER_NAMES = {
	"HP_variable_cutoff.c",
	"LPC_analysis_filter_FLP.c",
	"LPC_inv_pred_gain_FLP.c",
	"LTP_analysis_filter_FLP.c",
	"LTP_scale_ctrl_FLP.c",
	"NLSF_encode.c",
	"NSQ.c",
	"NSQ_del_dec.c",
	"VAD.c",
	"ana_filt_bank_1.c",
	"analysis.c",
	"apply_sine_window_FLP.c",
	"autocorrelation_FLP.c",
	"burg_modified_FLP.c",
	"bwexpander_FLP.c",
	"celt_encoder.c",
	"check_control_input.c",
	"control_SNR.c",
	"control_audio_bandwidth.c",
	"control_codec.c",
	"corrMatrix_FLP.c",
	"enc_API.c",
	"encode_frame_FLP.c",
	"encode_indices.c",
	"encode_pulses.c",
	"energy_FLP.c",
	"find_LPC_FLP.c",
	"find_LTP_FLP.c",
	"find_pitch_lags_FLP.c",
	"find_pred_coefs_FLP.c",
	"init_encoder.c",
	"inner_product_FLP.c",
	"k2a_FLP.c",
	"mlp.c",
	"mlp_data.c",
	"noise_shape_analysis_FLP.c",
	"opus_encoder.c",
	"opus_multistream_encoder.c",
	"opus_projection_encoder.c",
	"pitch_analysis_core_FLP.c",
	"process_NLSFs.c",
	"process_gains_FLP.c",
	"quant_LTP_gains.c",
	"regularize_correlations_FLP.c",
	"repacketizer.c",
	"residual_energy_FLP.c",
	"resampler_down2.c",
	"resampler_down2_3.c",
	"scale_copy_vector_FLP.c",
	"scale_vector_FLP.c",
	"schur_FLP.c",
	"sigm_Q15.c",
	"sort_FLP.c",
	"stereo_LR_to_MS.c",
	"stereo_encode_pred.c",
	"warped_autocorrelation_FLP.c",
	"wrappers_FLP.c",
}

---@type table<string, boolean>
local ENCODER_SOURCES = {}
for _, name in ipairs(ENCODER_NAMES) do
	ENCODER_SOURCES[name] = true
end

--- The opus source lists, per makefile fragment upstream keeps them in.
local OPUS_LISTS = {
	{ file = "celt_sources.mk", names = { "CELT_SOURCES" } },
	-- The float list holds the decoder's wrappers around the fixed point ones.
	{ file = "silk_sources.mk", names = { "SILK_SOURCES", "SILK_SOURCES_FLOAT" } },
	{ file = "opus_sources.mk", names = { "OPUS_SOURCES", "OPUS_SOURCES_FLOAT" } },
}

--- djb2, so any change to the recipe parts below builds a fresh library. A plain
--- FNV-1a multiply would lose precision in a Lua double.
---@param text string
local function hash(text)
	local value = 5381

	for i = 1, #text do
		value = bit.band(value * 33 + text:byte(i), 0xffffffff)
	end

	return string.format("%08x", value)
end

---@param entry treble.Vendored
local function fetch(entry)
	if build:exists(entryDir(entry)) then
		return
	end

	local archive = string.format("%s/%s.tar.gz", CACHE_DIR, entry.name)
	local url = string.format("https://github.com/%s/archive/refs/tags/%s.tar.gz", entry.repo, entry.tag)

	build:write(archive, build:fetch(url))
	build:extract(archive, CACHE_DIR .. "/" .. entry.name)
	build:delete(archive)
end

--- ogg ships this header as a template that only its configure script fills in.
---@param oggDir string
local function writeOggConfig(oggDir)
	build:write(oggDir .. "/include/ogg/config_types.h", [[
#ifndef __CONFIG_TYPES_H__
#define __CONFIG_TYPES_H__
#include <inttypes.h>
#include <stdint.h>
typedef int16_t ogg_int16_t;
typedef uint16_t ogg_uint16_t;
typedef int32_t ogg_int32_t;
typedef uint32_t ogg_uint32_t;
typedef int64_t ogg_int64_t;
typedef uint64_t ogg_uint64_t;
#endif
]])
end

--- Reads the C files out of one of upstream's makefile fragments, skipping the
--- per architecture lists that need flags this build does not pass.
---@param path string
---@param names string[]
local function sourceList(path, names)
	local wanted = {}
	for _, name in ipairs(names) do
		wanted[name] = true
	end

	---@type string[]
	local sources = {}
	local collecting = false

	for line in build:read(path):gmatch("[^\n]+") do
		local header = line:match("^([%u%d_]+) = \\$")
		if header then
			collecting = wanted[header] == true
		elseif collecting then
			local source = line:match("^(%S+%.c)")
			if source then
				sources[#sources + 1] = source
			end
		end
	end

	return sources
end

-- What Lua calls through ffi.load. An MSVC linked DLL exports nothing on its own,
-- and its linker takes no wildcards, so the names are listed. Keeping this in step
-- with the bindings is the same obligation the ELF version script has.
local EXPORTED = {
	"op_channel_count",
	"op_free",
	"op_open_file",
	"op_open_memory",
	"op_pcm_seek",
	"op_pcm_total",
	"op_read",
	"op_seekable",
	"op_tags",
	"treble_flac_channels",
	"treble_flac_close",
	"treble_flac_comment_count",
	"treble_flac_comment_size",
	"treble_flac_comments",
	"treble_flac_frame_count",
	"treble_flac_open_file",
	"treble_flac_open_memory",
	"treble_flac_picture_data",
	"treble_flac_picture_description",
	"treble_flac_picture_mime",
	"treble_flac_picture_size",
	"treble_flac_read_s16",
	"treble_flac_sample_rate",
	"treble_flac_seek",
	"treble_flac_vendor",
	"treble_mp3_channels",
	"treble_mp3_close",
	"treble_mp3_frame_count",
	"treble_mp3_open_file",
	"treble_mp3_open_memory",
	"treble_mp3_read_s16",
	"treble_mp3_sample_rate",
	"treble_mp3_seek",
	"treble_mp3_tag_data",
	"treble_mp3_tag_kind",
	"treble_mp3_tag_size",
}

---@type string[]
local objects = {}

--- Compiles sources relative to the output directory into objects next to them.
---@param sources string[]
---@param flags string[]
local function compile(sources, flags)
	local args = { "-c", "-O2", "-ffunction-sections", "-fdata-sections" }

	-- Position independent code is only meaningful where the loader needs it, and
	-- the MSVC target rejects the option outright.
	if not isWindows then
		args[#args + 1] = "-fPIC"
	end

	for _, flag in ipairs(flags) do
		args[#args + 1] = flag
	end

	for _, source in ipairs(sources) do
		args[#args + 1] = source
		objects[#objects + 1] = source:match("[^/]+$"):gsub("%.c$", ".o")
	end

	build:cc(args)
end

local shim = build:read("native/mp3.c") .. build:read("native/flac.c")
if isMac then
	shim = shim .. build:read("native/coreaudio.c")
end
local cacheKey = table.concat({ RECIPE_VERSION, DR_MP3_VERSION, DR_FLAC_VERSION, OGG_VERSION, OPUS_VERSION, OPUSFILE_VERSION, build.target, hash(shim) }, "-")
local cachedLibrary = string.format("%s/%s-%s-%s", CACHE_DIR, CACHE_NAME, cacheKey, libraryName)

if build:exists(cachedLibrary) then
	build:copy(cachedLibrary, libraryName)
	return
end

for _, entry in ipairs(VENDORED) do
	fetch(entry)
end

local drMp3Dir = entryDir(VENDORED[1])
local drFlacDir = entryDir(VENDORED[2])
local oggDir = entryDir(VENDORED[3])
local opusDir = entryDir(VENDORED[4])
local opusfileDir = entryDir(VENDORED[5])

writeOggConfig(oggDir)

-- libogg
compile({ oggDir .. "/src/bitwise.c", oggDir .. "/src/framing.c" }, { "-I" .. oggDir .. "/include" })

-- libopus, without its DEEP_PLC and DRED extras: those need generated weight
-- blobs and nothing here decodes them.
local opusSources = {}
for _, list in ipairs(OPUS_LISTS) do
	for _, source in ipairs(sourceList(opusDir .. "/" .. list.file, list.names)) do
		if not ENCODER_SOURCES[source:match("[^/]+$")] then
			opusSources[#opusSources + 1] = opusDir .. "/" .. source
		end
	end
end

compile(opusSources, {
	"-DOPUS_BUILD",
	"-DVAR_ARRAYS",
	"-I" .. opusDir .. "/include",
	"-I" .. opusDir .. "/celt",
	"-I" .. opusDir .. "/silk",
	"-I" .. opusDir .. "/silk/float",
})

-- libopusfile, which reads the ogg container and seeks inside it
compile({
	opusfileDir .. "/src/info.c",
	opusfileDir .. "/src/internal.c",
	opusfileDir .. "/src/opusfile.c",
	opusfileDir .. "/src/stream.c",
}, {
	"-I" .. opusfileDir .. "/include",
	"-I" .. oggDir .. "/include",
	"-I" .. opusDir .. "/include",
})

-- dr_mp3 and dr_flac behind the shims in src/native, copied in as native/*.c
compile({ "native/mp3.c" }, { "-I" .. drMp3Dir })
compile({ "native/flac.c" }, { "-I" .. drFlacDir })

-- The macOS backend needs the system audio frameworks, not a vendored library.
if isMac then
	compile({ "native/coreaudio.c" }, {})
end

-- Only these symbols are called from Lua. Hiding the rest lets the linker drop
-- every vendor function that nothing reaches, which is most of libopus.
local EXPORTS = "{\n\tglobal:\n\t\ttreble_*;\n\t\top_*;\n\tlocal:\n\t\t*;\n};\n"

build:write("exports.map", EXPORTS)

local linkArgs = { }

if isMac then
	linkArgs[#linkArgs + 1] = "-dynamiclib"
	linkArgs[#linkArgs + 1] = "-Wl,-dead_strip"
	linkArgs[#linkArgs + 1] = "-framework"
	linkArgs[#linkArgs + 1] = "AudioToolbox"
	linkArgs[#linkArgs + 1] = "-framework"
	linkArgs[#linkArgs + 1] = "CoreAudio"
	linkArgs[#linkArgs + 1] = "-framework"
	linkArgs[#linkArgs + 1] = "CoreFoundation"
else
	linkArgs[#linkArgs + 1] = "-shared"

	if isMsvc then
		-- lld-link and link.exe spell dead code elimination this way, and they need
		-- to be told what to export.
		local definition = { "EXPORTS" }
		for _, name in ipairs(EXPORTED) do
			definition[#definition + 1] = name
		end

		build:write("exports.def", table.concat(definition, "\n") .. "\n")
		linkArgs[#linkArgs + 1] = "-Wl,/OPT:REF"
		linkArgs[#linkArgs + 1] = "-Wl,/DEF:exports.def"
	else
		linkArgs[#linkArgs + 1] = "-Wl,--gc-sections"
	end

	-- Windows fails on undefined symbols anyway; ELF hides them until a call
	-- crashes, which would turn a missing source file into a runtime fault.
	if not isWindows then
		linkArgs[#linkArgs + 1] = "-Wl,--no-undefined"

		-- A version script is ELF's way of saying what a shared library exports.
		-- macOS would need -exported_symbols_list and Windows a .def file.
		linkArgs[#linkArgs + 1] = "-Wl,--version-script=exports.map"
	end
end

linkArgs[#linkArgs + 1] = "-o"
linkArgs[#linkArgs + 1] = libraryName

for _, object in ipairs(objects) do
	linkArgs[#linkArgs + 1] = object
end

-- MSVC has no separate math library to link against.
if not isWindows then
	linkArgs[#linkArgs + 1] = "-lm"
end

build:cc(linkArgs)

for _, object in ipairs(objects) do
	build:delete(object)
end

if not build:exists(libraryName) then
	error("the C decoders did not link into " .. libraryName)
end

build:copy(libraryName, cachedLibrary)
