# sing

Isolate vocals or suppress them from the terminal, using the voice models already on your Mac.

```sh
sing vocals song.mp3 -o vocals.wav
sing instrumental song.mp3 -o instrumental.wav
```

`sing` wraps Apple's **AUSoundIsolation** Audio Unit. Audio stays on your computer. There are no model downloads, API keys, dependencies, or bundled weights.

## Install

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). Building requires Swift 5.9 or later.

```sh
git clone https://github.com/rayhanadev/sing.git
cd sing
make install
```

This installs to `~/.local/bin/sing`. Add that directory to your `PATH` if needed:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

To choose an install location, use `make install PREFIX=/your/prefix`. You can also run the binary directly after `swift build -c release`:

```sh
"$(swift build -c release --show-bin-path)/sing" --help
```

## Use

```sh
# Keep the voice; suppress the background.
sing vocals recording.m4a -o voice.wav

# Suppress the voice; keep the remaining audio.
sing instrumental song.wav -o backing.wav

# Partially suppress the voice.
sing process song.wav -o quieter-vocals.wav --mix -60

# Select the standard model instead of the high-quality model.
sing vocals recording.wav -o voice.wav --quality standard

# Inspect what's available on this Mac.
sing info
```

| Option | Meaning |
| --- | --- |
| `-o`, `--output` | Required output path, ending in `.wav`. |
| `--mix` | For `process`: −100 suppresses voice, 0 preserves the original mix, +100 isolates voice. |
| `--quality` | `auto` (default), `high`, or `standard`. Auto selects high when available. |
| `--force` | Replace an existing output only after processing succeeds. |
| `--json` | Emit a machine-readable result. Errors go to stderr as JSON. |

Input can be any mono or stereo audio file AVFoundation can decode, including WAV, AIFF, MP3, M4A/AAC, and FLAC. Output is **32-bit float WAV** at the input's sample rate and channel count. The processor's reported latency is trimmed and its remaining output is flushed, retaining the original frame count. Files are streamed in small blocks.

Use `--` before an input filename that begins with a dash. Input files are never modified. Existing output needs `--force`, and using the input itself as the output is rejected, including symlinks and hard links. Output directories must already exist. WAV exports larger than 4 GiB are rejected.

## Use from scripts and agents

```sh
sing info --json
sing vocals input.wav -o output.wav --json
```

Successful processing returns the absolute input and output paths, selected model, mix, sample rate, channel count, frame count, duration, processing time, and compensated latency. Stdout contains only the JSON result. Exit codes are `0` for success, `1` for processing or file errors, and `2` for invalid arguments. Error JSON contains `error` and a numeric `exitCode` on stderr.

## What model is this?

The public Audio Toolbox component is [`kAudioUnitSubType_AUSoundIsolation`](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_ausoundisolation), identified by `aufx / vois / appl`. Standard voice isolation is available from macOS 13; the high-quality model is available from macOS 15. `sing` checks the installed component's parameter ranges before using either model or a negative mix.

On the Mac used to develop this tool, its resources are in:

```text
/System/Library/Components/AudioDSP.component/Contents/Resources/Tunings/Generic/AU/SoundIsolation/
```

The current resources include `vi-nnet-voice.mil`, `vi-nnet-high-quality-voice.mil`, and their corresponding `weights/*.weight.bin` files. The CLI calls the installed Audio Unit, so it does not depend on those private file paths or load the weights itself.

This project was prompted by [Noah's post about an on-device karaoke model](https://x.com/itsnoahd/status/2116325800513257633). **We have not established that AUSoundIsolation uses the same weights as Apple Music Sing.** It is a voice-isolation processor: results vary with the recording, vocals may leak into the backing track, and this is not a four-stem music separator. Model and parameter availability can vary by macOS version.

## Development

```sh
swift test
swift build -c release
python3 scripts/smoke.py "$(swift build -c release --show-bin-path)/sing"
```

The integration tests run the real Audio Unit on generated audio. They check sample alignment at different sample rates, stereo preservation, reconstruction from vocals plus instrumentals, very short files, and file-overwrite protection. The smoke test exercises the executable and its JSON interface. No audio fixtures or model files are committed.

MIT licensed CLI code. Apple's system components and model weights are not included and remain Apple's.
