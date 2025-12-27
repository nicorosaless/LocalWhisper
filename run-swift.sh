#!/bin/bash
# Run WhisperMac Swift version

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Build if needed
# Always build (incremental is fast)
echo "Compilando..."
cd swift && swift build -c release && cd ..

# Run from the main directory so paths work
./swift/.build/release/LocalWhisper
