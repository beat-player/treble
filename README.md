# treble

A cross platform playback audio library for LuaJIT.

## Features

- Audio Playback
- Metadata Parsing

## Backends

| Backend   | Windows | Linux | macOS | Android |
| --------- | ------- | ----- | ----- | ------- |
| WASAPI    | ✅      | ❌    | ❌    | ❌      |
| ALSA      | ❌      | ✅    | ❌    | ❌      |
| CoreAudio | ❌      | ❌    | ✅    | ❌      |
| AAudio    | ❌      | ❌    | ❌    | ✅      |

Android playback uses AAudio, so it needs Android 8.0 (API 26) or newer. The
backend is selected by the platform's feature flag, so an Android build contains
AAudio alone and a desktop build contains just its own backend.

## Formats

| Format          | Decoder     | Tags                      |
| --------------- | ----------- | ------------------------- |
| WAV             | built in    | `INFO` chunks             |
| FLAC            | dr_flac     | Vorbis comments, pictures |
| MP3             | dr_mp3      | ID3v2, ID3v1, pictures    |
| Ogg Opus        | libopusfile | Vorbis comments, pictures |
| AAC (MP4, .m4a) | FDK-AAC     | iTunes `ilst`, pictures   |

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

`pause()` keeps the output open so resuming is instant. `suspend()`, on a paused
player, closes the output instead: the source stays at the exact position the
device had played to, and `play()` opens the device again from there. A paused app
that calls `suspend()` therefore lets the audio device sleep. `latency()` reports
the device delay in frames, as the last `update()` read it.

## Equalizer

`Player:setEqualizer` replaces the filters on the decoded PCM before the volume
stage; pass `nil` to remove them.

```lua
player:setEqualizer({
	preamp = -4,
	{ frequency = 60, gain = 5, q = 1.0, type = "peak" },
	{ frequency = 105, gain = 5, q = 0.7, type = "lowshelf" },
	{ frequency = 10000, gain = -3, q = 0.7, type = "highshelf" },
	{ frequency = 20000, gain = 0, q = 0.7, type = "highpass" },
})
```

Each band is a biquad built from the RBJ cookbook. `type` is `peak` (the default),
`lowshelf`, `highshelf`, `lowpass` or `highpass`. A peak or shelf uses `gain`, in dB
clamped to ±24, and `q`, which defaults to 1.0 for a peak and 0.707 otherwise.
A low or high pass has no gain and passes `q` the same way. Bands at or above 0.95
times the Nyquist frequency are left out, and a peak or shelf at zero gain is
skipped; a pass filter is never skipped.

`preamp`, in dB clamped to -24..+12, scales the chunk before the filters, which is
how a profile that boosts bands avoids clipping. A preamp on its own keeps the
equalizer active, and so does a pass filter with no gain.

An imported parametric profile (AutoEq, EqualizerAPO) can be expressed with the
same table: a `Preamp:` line becomes `preamp`, and `PK`, `LSC`/`LS`, `HSC`/`HS`,
`LP`/`LPQ` and `HP`/`HPQ` lines become `peak`, `lowshelf`, `highshelf`, `lowpass`
and `highpass` bands.

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

Tags can be written back into FLAC, Ogg Opus, Ogg Vorbis, MP3 and MP4/M4A files:

```lua
assert(treble.Audio.writeTags("album/01.flac", { title = "New title", track = 3, genre = false }))
```

A field left out stays as the file has it, `false` removes it, and a value sets it.
Everything else in the file is kept: pictures, other tags and the audio, so the
fingerprint does not change. The file is read whole and the new one replaces it
through a temporary file beside it.

## Building

The compressed formats are vendored C sources, so `build.lua` fetches them and
compiles them when the package is installed. lde needs a C and C++ compiler on
the PATH (FDK-AAC is C++, built without its standard library).

See [ATTRIBUTIONS.md](./ATTRIBUTIONS.md) for what is vendored.
