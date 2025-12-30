# Local Whisper

Local speech-to-text for macOS using whisper.cpp.

**Website & Download:** [local-whisper.netlify.app](https://local-whisper.netlify.app)

## Features

- Customizable hotkeys (Push-to-Talk and Toggle modes)
- Fully local transcription using whisper.cpp
- Native Swift application for Apple Silicon
- Auto-paste transcribed text to the active application

## Usage

1. **Install**: Drag the app to the Applications folder.
2. **Setup**: On first launch, grant Accessibility permissions (required for hotkey detection).
3. **Customize**: Open settings to configure your preferred hotkey and recording mode.
4. **Transcribe**: Use your hotkey to record. Transcription happens locally and text is pasted automatically.

## Requirements

- macOS 13+ (Apple Silicon recommended)

## Development

### Prerequisites
- Xcode 15+
- Node.js 18+ (for web)

### Build
Run the swift build script:
```bash
./scripts/build.sh
```

## License

MIT License
