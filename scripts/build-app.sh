#!/bin/bash
set -e

echo "🔨 Building LocalWhisper.app..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SWIFT_DIR="${PROJECT_DIR}/swift"

cd "${SWIFT_DIR}"

# Build release
echo "📦 Compiling release build..."
swift build -c release

# Build optional Rust daemon backend (if cargo is available)
RUST_DAEMON_SOURCE="${PROJECT_DIR}/rust/qwen-daemon/target/release/qwen-daemon"
if command -v cargo >/dev/null 2>&1; then
    if [ -f "${PROJECT_DIR}/rust/qwen-daemon/Cargo.toml" ]; then
        echo "🦀 Building Rust qwen-daemon..."
        cargo build --release --manifest-path "${PROJECT_DIR}/rust/qwen-daemon/Cargo.toml"
    fi
else
    echo "⚠️  cargo not found; skipping Rust daemon build (Python backend will be used)."
fi

# Create app bundle structure
APP_NAME="LocalWhisper"
APP_DIR="${PROJECT_DIR}/build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
BIN_DIR="${RESOURCES_DIR}/bin"

# Clean and create directories
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"
mkdir -p "${BIN_DIR}"

# Copy executable
cp ".build/release/LocalWhisper" "${MACOS_DIR}/LocalWhisper"

# Copy whisper-cli binary if exists
if [ -f "${PROJECT_DIR}/bin/whisper-cli" ]; then
    cp "${PROJECT_DIR}/bin/whisper-cli" "${BIN_DIR}/"
    chmod +x "${BIN_DIR}/whisper-cli"
fi

# Copy Rust daemon if available
if [ -f "${RUST_DAEMON_SOURCE}" ]; then
    cp "${RUST_DAEMON_SOURCE}" "${BIN_DIR}/qwen-daemon"
    chmod +x "${BIN_DIR}/qwen-daemon"
    echo "🦀 Bundled Rust daemon: ${BIN_DIR}/qwen-daemon"
fi

# Copy models directory if exists
if [ -d "${PROJECT_DIR}/models" ]; then
    cp -r "${PROJECT_DIR}/models" "${RESOURCES_DIR}/"
fi

# Copy Python transcription script
echo "📦 Copying transcribe.py..."
mkdir -p "${RESOURCES_DIR}/scripts"
cp "${PROJECT_DIR}/scripts/transcribe.py" "${RESOURCES_DIR}/scripts/"

# Copy Icon
if [ -f "${PROJECT_DIR}/assets/AppIcon.icns" ]; then
    echo "🎨 Copying app icon..."
    cp "${PROJECT_DIR}/assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>LocalWhisper</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.nicorosaless.LocalWhisper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>LocalWhisper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>LocalWhisper needs microphone access to transcribe your voice.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LocalWhisper needs to send events to paste transcribed text.</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Create entitlements file
ENTITLEMENTS_FILE="${PROJECT_DIR}/build/app.entitlements"
cat > "${ENTITLEMENTS_FILE}" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
EOF

# Sign the app with ad-hoc signature (works without Apple Developer account)
echo "✍️ Signing app..."
codesign --force --deep --sign - "${APP_DIR}"

# Also sign with entitlements for Accessibility
codesign --force --deep --sign - --entitlements "${ENTITLEMENTS_FILE}" "${APP_DIR}"

echo "✅ Build complete: ${APP_DIR}"
echo ""
echo "🧠 RAM optimization runtime flags:"
echo "   LOCALWHISPER_QWEN_BACKEND=rust     # force Rust daemon wrapper"
echo "   LOCALWHISPER_LOW_RAM=0             # disable low-RAM idle unload"
echo "   LOCALWHISPER_IDLE_UNLOAD_SECONDS=25"
echo ""
echo "   Example:"
echo "   LOCALWHISPER_QWEN_BACKEND=rust open \"${APP_DIR}\""
echo ""
echo "📋 IMPORTANT: To fix Accessibility permissions:"
echo "   1. Open System Settings > Privacy & Security > Accessibility"
echo "   2. Click the '+' button"
echo "   3. Navigate to: ${APP_DIR}"
echo "   4. Add it to the list"
echo ""
echo "🚀 To run: open \"${APP_DIR}\""
