-- A small graphic equalizer: one peaking biquad per band, run over decoded PCM before
-- the volume stage. The coefficients follow the RBJ cookbook, which is the same shape
-- most software equalizers use; keeping the state here means a changed band is heard
-- on the next decoded chunk rather than only after a track restart.
--
-- The filters have nothing to do with the device: the caller names a sample rate when
-- it processes a chunk, and a new rate or channel count resets the state. That is what
-- lets one Player move between files without leaking a filter's history across them.
local ffi = require("ffi")

local abs = math.abs
local cos = math.cos
local floor = math.floor
local max = math.max
local min = math.min
local pi = math.pi
local sin = math.sin

local MIN_GAIN = -24
local MAX_GAIN = 24
local MIN_FREQUENCY = 10
local MIN_SAMPLE = -32768
local MAX_SAMPLE = 32767

---@class treble.Equalizer.Band
---@field frequency number # Centre, in hertz
---@field gain number # dB at the centre
---@field q number? # Bandwidth; 1.0 is the default for octave-spaced bands

---@class treble.Equalizer
---@field bands treble.Equalizer.Band[]
---@field coefficients ffi.cdata*? # double[count * 5]: b0, b1, b2, a1, a2 for each band that does anything
---@field count number # How many bands the coefficients hold
---@field sampleRate number?
---@field channels number?
---@field history ffi.cdata*? # double[channels * count * 4]: x1, x2, y1, y2 for each channel's band
---@field scratch ffi.cdata*? # double[scratchSize]: a chunk while it goes through the bands
---@field scratchSize number
local Equalizer = {}
Equalizer.__index = Equalizer

---@param bands treble.Equalizer.Band[]?
---@return treble.Equalizer
function Equalizer.new(bands)
	local equalizer = setmetatable({
	bands = {},
	coefficients = nil,
	count = 0,
	sampleRate = nil,
	channels = nil,
	history = nil,
	scratch = nil,
	scratchSize = 0,
	}, Equalizer)

	if bands ~= nil then equalizer:setBands(bands) end
	return equalizer
end

---@param value any
---@param fallback number
---@return number
local function number(value, fallback)
	if type(value) ~= "number" or value ~= value then return fallback end
	return value
end

--- Replaces the bands and drops the history: a coefficient built for the old shape
--- cannot describe the new one, and carrying a stale ring through a preset change
--- makes the first chunk ring.
---@param bands treble.Equalizer.Band[]
function Equalizer:setBands(bands)
	local clean = {}
	for at = 1, #bands do
			local band = bands[at]
			if type(band) == "table" then
				local frequency = number(band.frequency, 0)
				local gain = number(band.gain, 0)
				if frequency > 0 then
					clean[#clean + 1] = {
					frequency = max(MIN_FREQUENCY, frequency),
					gain = max(MIN_GAIN, min(MAX_GAIN, gain)),
					q = max(0.1, number(band.q, 1.0)),
					}
				end
			end
		end
	self.bands = clean
	self.sampleRate = nil
	self.channels = nil
	self.coefficients = nil
	self:reset()
end

---@return boolean
function Equalizer:isFlat()
	for at = 1, #self.bands do
			if abs(self.bands[at].gain) >= 0.01 then return false end
		end
	return true
end

function Equalizer:reset()
	local history = self.history
	if history ~= nil then ffi.fill(history, ffi.sizeof(history)) end
end

---@param bands treble.Equalizer.Band[]
---@param sampleRate number
---@return number[][]
local function buildCoefficients(bands, sampleRate)
	local made = {}
	local nyquist = sampleRate / 2

	for at = 1, #bands do
			local band = bands[at]
			if abs(band.gain) >= 0.01 and band.frequency < nyquist * 0.95 then
				local gain = band.gain
				local frequency = band.frequency
				local q = band.q or 1.0
				local a = 10 ^ (gain / 40)
				local omega = 2 * pi * frequency / sampleRate
				local alpha = sin(omega) / (2 * q)
				local cosOmega = cos(omega)

				local b0 = 1 + alpha * a
				local b1 = -2 * cosOmega
				local b2 = 1 - alpha * a
				local a0 = 1 + alpha / a
				local a1 = -2 * cosOmega
				local a2 = 1 - alpha / a

				made[#made + 1] = { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0}
			end
		end

	return made
end

---@param sampleRate number
---@param channels number
function Equalizer:configure(sampleRate, channels)
	if sampleRate <= 0 or channels <= 0 then return end
	if self.sampleRate == sampleRate and self.channels == channels and self.coefficients ~= nil then
		return
	end

	self.sampleRate = sampleRate
	self.channels = channels
	local made = buildCoefficients(self.bands, sampleRate)
	local count = #made
	local coefficients = ffi.new("double[?]", max(1, count * 5))
	for band = 1, count do
			for at = 1, 5 do coefficients[(band - 1) * 5 + at - 1] = made[band][at] end
		end
	self.coefficients = coefficients
	self.count = count
	-- A new array is a zeroed one: the history starts over with the shape.
	self.history = ffi.new("double[?]", max(1, channels * count * 4))
end

--- Applies the bands in place. The caller's samples stay int16 so the volume stage,
--- the PCM tap, and the device all keep seeing the shape treble has already used.
---
--- This runs on every sample that plays, so it is laid out for the JIT: the chunk is taken into
--- doubles once, each band of each channel is one loop over it with its coefficients and history
--- in locals, and the result is rounded back once. Nothing in it allocates once the scratch has
--- grown to the chunk size.
---@param samples ffi.cdata*
---@param frames number
---@param channels number
---@param sampleRate number
function Equalizer:process(samples, frames, channels, sampleRate)
	if #self.bands == 0 or frames <= 0 or channels <= 0 then return end

	self:configure(sampleRate, channels)
	local count = self.count
	if count == 0 then return end

	local total = frames * channels
	if self.scratchSize < total then
		self.scratch = ffi.new("double[?]", total)
		self.scratchSize = total
	end
	local scratch = assert(self.scratch)
	for at = 0, total - 1 do scratch[at] = samples[at] end

	local coefficients = assert(self.coefficients)
	local history = assert(self.history)
	for channel = 0, channels - 1 do
			for band = 0, count - 1 do
					local c = band * 5
					local b0, b1, b2 = coefficients[c], coefficients[c + 1], coefficients[c + 2]
					local a1, a2 = coefficients[c + 3], coefficients[c + 4]
					local h = (channel * count + band) * 4
					local x1, x2, y1, y2 = history[h], history[h + 1], history[h + 2], history[h + 3]
					for at = channel, total - 1, channels do
							local x = scratch[at]
							local y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
							x2, x1 = x1, x
							y2, y1 = y1, y
							scratch[at] = y
						end
					history[h], history[h + 1], history[h + 2], history[h + 3] = x1, x2, y1, y2
				end
		end

	for at = 0, total - 1 do
			samples[at] = max(MIN_SAMPLE, min(MAX_SAMPLE, floor(scratch[at] + 0.5)))
		end
end

return Equalizer
