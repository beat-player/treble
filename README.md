# treble

A cross platform playback audio library for LuaJIT.

## Features

- Audio Playback
- Metadata Parsing

## Backends

| Backend   | Windows | Linux | macOS |
| --------- | ------- | ----- | ----- |
| WASAPI    | ✅      | ❌    | ❌    |
| ALSA      | ❌      | ✅    | ❌    |
| CoreAudio | ❌      | ❌    | ✅    |

## Formats

| Format   | Decoder     | Tags                      |
| -------- | ----------- | ------------------------- |
| WAV      | built in    | `INFO` chunks             |
| FLAC     | dr_flac     | Vorbis comments, pictures |
| MP3      | dr_mp3      | ID3v2, ID3v1, pictures    |
| Ogg Opus | libopusfile | Vorbis comments, pictures |

A picture comes back as its MIME type and its raw bytes, to hand to an image
library.

## Installation

Use this package with the [lde](https://lde.sh/) package manager.

```bash
lde add treble
```

## Usage

Play a sound with one call:

```lua
local treble = require("treble")

treble.play("jump.wav", 0.5)
```

For music, drive a player from your frame loop:

```lua
local treble = require("treble")

local player = treble.Player.new()
player:enqueue("album/01.flac")
player:enqueue("album/02.flac")
player:play()

player:update() -- once a frame, which is what feeds the device
print(player:position(), player:duration())
player:seek(30)
player:next()
player:stop()
```

Queued tracks run back to back without a gap, position and seeking come from the
device clock, and `player.onTrackEnd` and `player.onError` report what happened.

## Metadata

A scan can ask a file what it is without opening a decoder:

```lua
local treble = require("treble")

local info = assert(treble.Audio.inspect("album/01.flac"))
print(info.format, info.duration, info.tags and info.tags.title)
```

`inspect` returns the format, sample rate, channels, duration and the text tags.
`info.hasPicture` says whether cover art is attached; the picture bytes are not
copied by a scan. Read them with `treble.Audio.tags` when a view needs them.

`info.fingerprint` is 16 lowercase hex digits over the audio itself: the format,
the duration in whole milliseconds, and 16 KiB of the payload at the start, at
1 MiB and at 4 MiB. Tag edits, a changed picture, a rewritten comment and a moved
or renamed file do not change it. A library can therefore keep ratings, play
counts and hand-added playlist entries attached to the recording instead of to
the path. It is a fingerprint, not a guarantee: two different recordings can
collide, and a difference that falls outside the sampled windows is not seen.
`fingerprint` is `nil` only when the audio payload cannot be read at all.

## Building

The compressed formats are vendored C sources, so `build.lua` fetches them and
compiles them when the package is installed. lde needs a C compiler on the PATH.

See [ATTRIBUTIONS.md](./ATTRIBUTIONS.md) for what is vendored.
