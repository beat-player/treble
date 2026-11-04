-- A small graphic equalizer: one peaking biquad per band, run over decoded PCM before
-- the volume stage. The coefficients follow the RBJ cookbook, which is the same shape
-- most software equalizers use; keeping the state here means a changed band is heard
-- on the next decoded chunk rather than only after a track restart.
--
-- The filters have nothing to do with the device: the caller names a sample rate when
-- it processes a chunk, and a new rate or channel count resets the state. That is what
-- lets one Player move between files without leaking a filter's history across them.
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
---@field coefficients number[][]?
---@field sampleRate number?
---@field channels number?
---@field x1 number[]
---@field x2 number[]
---@field y1 number[]
---@field y2 number[]
local Equalizer = {}
Equalizer.__index = Equalizer

---@param bands treble.Equalizer.Band[]?
---@return treble.Equalizer
function Equalizer.new(bands)
	local equalizer = setmetatable({
	bands = {},
	coefficients = nil,
	sampleRate = nil,
	channels = nil,
	x1 = {},
	x2 = {},
	y1 = {},
	y2 = {},
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
	for at = 1, #self.x1 do
			self.x1[at], self.x2[at], self.y1[at], self.y2[at] = 0, 0, 0, 0
		end
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

---@param channels number
---@param count number
local function clearState(equalizer, channels, count)
	local size = channels * count
	for at = 1, size do
			equalizer.x1[at], equalizer.x2[at] = 0, 0
			equalizer.y1[at], equalizer.y2[at] = 0, 0
		end
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
	self.coefficients = buildCoefficients(self.bands, sampleRate)
	clearState(self, channels, #self.coefficients)
end

--- Applies the bands in place. The caller's samples stay int16 so the volume stage,
--- the PCM tap, and the device all keep seeing the shape treble has already used.
---@param samples ffi.cdata*
---@param frames number
---@param channels number
---@param sampleRate number
function Equalizer:process(samples, frames, channels, sampleRate)
	if #self.bands == 0 or frames <= 0 or channels <= 0 then return end

	self:configure(sampleRate, channels)
	local coefficients = self.coefficients
	local count = #coefficients
	if count == 0 then return end

	local x1, x2, y1, y2 = self.x1, self.x2, self.y1, self.y2

	for frame = 0, frames - 1 do
			local base = frame * channels
			for channel = 0, channels - 1 do
					local x = samples[base + channel]
					local lane = channel * count
					for band = 1, count do
							local c = coefficients[band]
							local state = lane + band
							local y = c[1] * x + c[2] * (x1[state] or 0) + c[3] * (x2[state] or 0)
							-c[4] * (y1[state] or 0) - c[5] * (y2[state] or 0)
							x2[state] = x1[state] or 0
							x1[state] = x
							y2[state] = y1[state] or 0
							y1[state] = y
							x = y
						end
					samples[base + channel] = max(MIN_SAMPLE, min(MAX_SAMPLE, floor(x + 0.5)))
				end
		end
end

return Equalizer
