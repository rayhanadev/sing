# Extracted AUSoundIsolation models

[`ausoundisolation/macos-27.2-26B5101f/`](ausoundisolation/macos-27.2-26B5101f/) contains the model resources extracted from Apple's AUSoundIsolation Audio Unit on macOS **27.2 (26B5101f)**. The 13 original files total **9,701,581 bytes**. Their bytes and directory layout are preserved.

| Model | Graph | Weights | Sample rate | Configured runtime |
| --- | --- | --- | --- | --- |
| High Quality Voice | `vi-nnet-high-quality-voice.mil` | `weights/vi-nnet-high-quality-voice.weight.bin` (3,896,576 bytes) | 32 kHz | MIL2BNNS / CPU |
| Standard Voice | `vi-nnet-voice.mil` | `weights/vi-nnet-voice.weight.bin` (2,246,144 bytes) | 24 kHz | MIL2BNNS / CPU |
| Legacy Voice v0 | `vois-vi-v0-nnet.espresso.net` | `vois-vi-v0-nnet.espresso.weights` (2,337,920 bytes) | 24 kHz | Espresso / CPU |

The snapshot also includes the Espresso `.shape` file, three model configuration plists, and three Audio Unit presets. [`manifest.json`](ausoundisolation/macos-27.2-26B5101f/manifest.json) maps each model to its graph, weights, configuration, block size, and lookahead. It records byte counts and SHA-256 hashes for every original asset.

## Source

The files were copied directly from:

```text
/System/Library/Components/AudioDSP.component/Contents/Resources/Tunings/Generic/AU/SoundIsolation/
```

The MIL graphs reference their weights through `@model_path/weights/…`. Keep that relative layout when inspecting or experimenting with them. The configuration plists retain their original absolute system paths.

## Verify

From the repository root:

```sh
cd models/ausoundisolation/macos-27.2-26B5101f
shasum -a 256 -c SHA256SUMS
```

CI runs this check on the files downloaded from GitHub.

## Runtime

These are raw MIL and Espresso model resources, not a ready-to-load `.mlmodel`, `.mlpackage`, or `.mlmodelc` bundle. The graphs include streaming state, and their configuration files describe the expected audio framing. Using them independently requires a compatible runtime and the corresponding audio processing pipeline.

`sing` continues to use the installed `aufx / vois / appl` Audio Unit. Adding this snapshot does not make the CLI portable to Linux or Windows or pin its inference behavior to these weights. Identity with Apple Music Sing's weights has not been established.

## Attribution

The model assets were produced by Apple. The repository's MIT license covers its own CLI code and supporting material, not these extracted assets. See [NOTICE](NOTICE).
