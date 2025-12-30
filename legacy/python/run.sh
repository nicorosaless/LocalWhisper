#!/bin/bash
# WhisperMac - Run script
# Launches the speech-to-text dictation app

cd "$(dirname "$0")"

# Check dependencies
if ! command -v whisper-cli &> /dev/null; then
    echo "❌ Error: whisper-cli not found. Install with: brew install whisper-cpp"
    exit 1
fi

if [ ! -f "models/ggml-large-v3-turbo.bin" ]; then
    echo "❌ Error: Model not found. Download it with:"
    echo "   curl -L -o models/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    exit 1
fi

# Run the app
python3 main.py
