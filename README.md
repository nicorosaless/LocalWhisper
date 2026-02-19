# LocalWhisper

A macOS menu bar application for fully local, low-latency speech-to-text transcription. Supports multiple inference backends and auto-pastes transcribed text into the active application.

**Website and download:** [local-whisper.netlify.app](https://local-whisper.netlify.app)

---

## Features

- Push-to-Talk and Toggle recording modes
- Configurable hotkey (any key combination, recorded via the Settings UI)
- Fully local transcription — no network calls during inference
- Native Swift application targeting Apple Silicon (ARM64)
- Auto-paste to the active application via CGEvent, AppleScript, or Accessibility API
- Multiple transcription backends selectable at runtime

---

## Transcription Backends

### whisper.cpp

The default backend. Uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) to run the `ggml-small` model (~466 MB). Mature, well-tested, real-time factor approximately 0.10.

### Qwen3-ASR 0.6B (4-bit quantized)

MLX-based inference of `mlx-community/Qwen3-ASR-0.6B-4bit`. Approximately 400 MB download. Real-time factor approximately 0.06 on Apple Silicon.

### Qwen3-ASR 1.7B (8-bit quantized)

MLX-based inference of `mlx-community/Qwen3-ASR-1.7B-8bit`. Approximately 2.5 GB download. Real-time factor approximately 0.11 on Apple Silicon.

Model weights are downloaded on first selection from HuggingFace and cached to `~/Library/Application Support/LocalWhisper/qwen3-cache/`. Download progress is shown inline in the Settings window.

---

## Requirements

- macOS 14 or later (Apple Silicon required for Qwen3 backends)
- Accessibility permission (required for hotkey detection and text injection)

---

## Usage

1. Install by dragging `LocalWhisper.app` to `/Applications`.
2. On first launch, grant Accessibility permission when prompted (System Settings > Privacy and Security > Accessibility).
3. Open Settings from the menu bar icon to configure your hotkey, recording mode, and transcription engine.
4. Use the configured hotkey to record. Transcription runs locally and the result is pasted into the focused application.

---

## Architecture

### Inference pipeline

```
Audio capture (CoreAudio)
  -> WAV buffer
  -> TranscriptionEngine.transcribe(audioURL:language:)
  -> Transcribed string
  -> Paste to active application (CGEvent / AppleScript / AX API)
```

### Qwen3-ASR architecture (Swift/MLX implementation)

The Qwen3-ASR model is a two-stage encoder-decoder architecture. The implementation in `swift/Sources/Engines/` is a hand-written Swift/MLX forward pass with no Python or external model-loading framework.

**Audio tower** (`audio_tower.*` weight keys):

- Three strided Conv2D layers (`conv2d1`, `conv2d2`, `conv2d3`), each with kernel 3x3, stride 2, padding 1, 480 channels. Input is a mel spectrogram with 128 mel bins.
- A linear projection `conv_out` of shape `[896, 7680]` that projects the flattened conv output (16 mel bins x 480 channels after three stride-2 layers) to the model dimension.
- 18 (0.6B) or 24 (1.7B) transformer encoder layers with pre-norm self-attention and pre-norm FFN (GELU activation).
- Final projection: `ln_post` -> `proj1 [896, 896]` -> `proj2 [textHiddenSize, 896]`.

**Text decoder** (`model.*` weight keys):

- Qwen3 decoder-only language model (28 layers for both sizes).
- Grouped-query attention: 16 heads, 8 KV heads, head dimension 128.
- Per-head QK RMSNorm (`q_norm`, `k_norm`).
- SwiGLU MLP (`gate_proj`, `up_proj`, `down_proj`).
- 4-bit affine quantized weights stored as packed U32 nibbles with `.weight`, `.scales`, and `.biases` keys. Dequantized on-the-fly in `QuantizedLinear`.
- Tied embeddings (embed_tokens shares weights with lm_head).

**Inference protocol (chat template):**

```
<|im_start|>system\n<system_text><|im_end|>\n
<|im_start|>user\n<|audio_start|>[N x <|audio_pad|>]<|audio_end|><|im_end|>\n
<|im_start|>assistant\n
```

Audio pad tokens (ID 151676) in the prompt embedding matrix are replaced with the output of the audio tower before the first decoder forward pass. Decoding stops on `<|im_end|>` (ID 151645) or after 512 tokens.

**Special token IDs:**

| Token | ID |
|---|---|
| `<\|im_start\|>` | 151644 |
| `<\|im_end\|>` | 151645 |
| `<\|audio_start\|>` | 151669 |
| `<\|audio_end\|>` | 151670 |
| `<\|audio_pad\|>` | 151676 |

**Tokenizer:**

Qwen2 BPE loaded from `vocab.json` and `merges.txt`. Encoding uses the GPT-2 byte-level unicode mapping (each raw UTF-8 byte is mapped to a printable unicode character before BPE merges are applied). Decoding reverses this mapping and reconstructs the UTF-8 string.

**Weight loading:**

`loadSafetensors()` parses the safetensors binary format directly in Swift, supporting F32, BF16, F16, U32, and I32 dtypes. Both single-file (`model.safetensors`) and sharded (`model.safetensors.index.json` + shards) layouts are supported.

### Hotkey detection

Hotkeys are registered via two complementary mechanisms:

1. **CGEventTap** — a low-level event tap at the `HID` level, which intercepts key events before they reach the application. Requires Accessibility permission.
2. **NSEvent global monitor** — a fallback for cases where the event tap is inactive or the system revokes it.

A watchdog timer periodically checks whether the event tap is still enabled and re-enables it if the system has disabled it (which macOS does automatically in some conditions).

### Text injection

Four paste strategies are attempted in order (or a specific one can be forced in Settings):

| Strategy | Mechanism |
|---|---|
| CGEvent | Synthesizes Cmd+V via `CGEvent(keyboardEventSource:virtualKey:keyDown:)` |
| AppleScript | `System Events.keystroke "v" using command down` |
| Accessibility API | `AXUIElementSetAttributeValue` with the transcribed string |
| Type simulation | Character-by-character `CGEvent` key events |

---

## Development

### Prerequisites

- Xcode 15 or later
- Swift 5.9 or later
- Node.js 18 or later (for the web landing page only)

### Build

```bash
./scripts/build-app.sh
```

This compiles the Swift package, bundles the binary into `build/LocalWhisper.app`, and re-signs the bundle. After each build the Accessibility permission entry must be re-granted because the bundle identity changes.

### Project structure

```
swift/
  Sources/
    main.swift                        # App delegate, hotkey handling, recording loop
    SettingsView.swift                # Settings UI (SwiftUI), includes QwenDownloadManager
    FloatingIndicator.swift           # Menu bar status indicator
    OnboardingView.swift              # First-launch onboarding
    ModelDownloader.swift             # whisper.cpp model download
    Models/
      EngineConfig.swift              # EngineType enum, QwenDownloadState, AppConfig
    Engines/
      TranscriptionEngine.swift       # Protocol definition
      WhisperCppEngine.swift          # whisper.cpp subprocess backend
      Qwen3ASREngine.swift            # Qwen3 engine: load, download, transcribe
      Qwen3Model.swift                # Qwen3ASRModel: config, weight loading, inference
      Qwen3Layers.swift               # All Swift/MLX layer implementations
      Tokenizer.swift                 # Qwen2 BPE tokenizer (vocab.json + merges.txt)
      MelSpectrogram.swift            # Mel spectrogram extraction (128 mels, 16 kHz)
      KVCache.swift                   # Legacy KV cache (superseded by GQAKVCache in Qwen3Layers)
scripts/
  build-app.sh                        # Build and sign script
web/                                  # Landing page (Netlify)
```

### Configuration file

Runtime configuration is persisted to `~/Library/Application Support/LocalWhisper/config.json`:

```json
{
  "language": "es",
  "hotkey": { "keyCode": 109, "modifiers": [], "keyCharacter": "F10" },
  "hotkey_mode": "toggle",
  "auto_paste": true,
  "model_path": "models/ggml-small.bin",
  "paste_delay": 80,
  "preferred_paste_method": "auto",
  "launch_at_login": false,
  "engine_type": "whisper.cpp"
}
```

---

## License

MIT License
