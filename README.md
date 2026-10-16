# zigaudioparser

A small audio reading library for **Zig 0.16.0**, developing native Zig container readers and
codecs.

## Quick start

```sh
zig build
zig build run -- path/to/audio.wav
```

```sh
zig build -Dopus=false -Dvorbis=false  # dependency-free pcm and flac build
zig build run -- path/to/audio.ogg
zig build test -Dopus=false -Dvorbis=false
```

## Roadmap

The goal is to read, decode, convert, encode, and write mainstream audio formats.

- [ ] create man pages
- [x] create unit tests (`zig build test`)

### WAV container

- [x] RF64 audio reading.
- [x] BW64 audio reading.
- [x] RIFX.
- [x] Wave64.
- [x] Segmented RIFF/RIFX audio (`LIST/wavl`, `data`, `slnt`).
- [ ] Compressed WAVE codec mapping and configuration (IMA ADPCM, Microsoft ADPCM, MP3).
- [ ] Compressed block and packet framing.
- [ ] Compressed audio timing, decoded sample trimming, and seeking.
- [ ] Preserve extensible channel masks for seekable input.

### Ogg container

- [x] Opus and Vorbis reading (single logical stream).
- [ ] Chained streams.
- [ ] Audio selection from multiplexed streams.
- [ ] Recovery after damaged or missing pages.
- [ ] Ogg FLAC mapping.

### Decoder support

- [x] PCM sample conversion to interleaved float32.
- [x] Ogg Opus and Vorbis packet framing and codec configuration.
- [x] PCM, Opus, and Vorbis state reset and seeking on seekable input.
- [x] Ogg Opus and Vorbis leading and trailing sample trimming, including Opus pre-skip.
- [x] Opus channel mapping and format-defined output gain.
- [ ] Framing and configuration for additional codecs.
- [ ] Compressed block decoding across reads.
- [ ] Decoder delay and end padding for additional codecs.
- [ ] Channel mapping and format-defined output gain for additional codecs.

### Audio conversion

- [ ] Configurable PCM output: integer and floating-point samples, bit depth, and byte order.
- [ ] Interleaved and planar sample layouts.
- [ ] Sample rate conversion with anti-aliasing and resampler delay handling.
- [ ] Channel reordering, mono/stereo conversion, and multichannel downmixing.
- [ ] Integer quantization, clipping control, and optional dithering when reducing precision.
- [ ] Preserve timing and sample counts across conversion and partial reads.

### Encoder and container writing support

- [ ] Encode PCM input to supported output codecs.
- [ ] Codec settings: bitrate, quality, rate control, and compression level where applicable.
- [ ] Validate codec, container, sample rate, channel layout, and sample format compatibility.
- [ ] Buffer encoder frames across writes and flush delayed packets at end of input.
- [ ] Record encoder delay, pre-skip, end padding, and packet timestamps where applicable.
- [ ] Write raw PCM with caller supplied sample format.
- [ ] Write encoded packets to compatible containers and streams.
- [ ] Finalize headers, sizes, sample counts, checksums, and seek indexes where applicable.
- [ ] Handle seekable output and streaming output where the format allows it.
- [ ] Write basic tags and embedded artwork where supported.
- [ ] Copy encoded packets between compatible containers without decoding.

### Metadata

- [ ] RIFF `LIST/INFO` tag reading.
- [ ] Technical metadata: stream properties and channel layouts.
- [ ] Descriptive tags: title, artist, album, track number, dates, and comments across formats.
- [ ] Embedded artwork.

### Codecs

- [ ] AAC.
- [ ] AC3.
- [ ] ADPCM IMA WAV.
- [ ] ADPCM Microsoft.
- [ ] A-law.
- [ ] ALAC.
- [ ] DTS.
- [ ] EAC3.
- [x] FLAC (native).
- [ ] MP3.
- [ ] Mu-law.
- [x] Opus (temporary libopus backend).
- [x] Vorbis (temporary libvorbis backend).
- [ ] Windows Media Audio 1.
- [ ] Windows Media Audio 2.

### Common audio containers and streams

- [ ] MP3 streams.
- [ ] Ogg container.
- [ ] ADTS.
- [x] FLAC (native files with seeking and id3v2 prefixes).
- [ ] M4A.
- [ ] AIFF.
- [ ] AIFC.
- [ ] CAF.
- [ ] WMA files.
- [ ] Raw PCM with caller supplied format.
