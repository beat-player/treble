local audio = require("treble.audio")
local Equalizer = require("treble.equalizer")
local Player = require("treble.player")

---@class treble
---@field Audio treble.audio
---@field Equalizer treble.Equalizer
---@field Player treble.Player
local treble = {}

treble.Audio = audio
treble.Equalizer = Equalizer
treble.Player = Player

--- One shot players from treble.play, kept only until their sound has finished.
---@type treble.Player[]
local oneShots = {}

local function reap()
	for i = #oneShots, 1, -1 do
			local player = oneShots[i]
			if player:isFinished() then
				player:close()
				table.remove(oneShots, i)
			end
		end
end

--- Plays a file or a source.
---
--- This is shorthand for Player.new():enqueue(item):play(), then handing the audio
--- to the device. It blocks only while the device is full, so a sound longer than
--- the device buffer holds up the caller for the part it cannot take — use a
--- Player in a frame loop for anything long.
---@param item string|treble.Source
---@param volume number?
---@return treble.Player
function treble.play(item, volume)
	reap()

	local player = Player.new()
	player:enqueue(item)

	if volume ~= nil then
		player:setVolume(volume)
	end

	player:play()
	player:pump()

	oneShots[#oneShots + 1] = player

	return player
end

--- Releases the device of any one shot sound that has finished. Worth calling once
--- a frame; a sound keeps playing without it.
function treble.update()
	reap()
end

return treble
