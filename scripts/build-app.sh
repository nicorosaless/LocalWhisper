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

# Create app bundle structure
APP_NAME="LocalWhisper"
APP_DIR="${PROJECT_DIR}/build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

# Clean and create directories
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"

# Copy executable
cp ".build/release/LocalWhisper" "${MACOS_DIR}/LocalWhisper"

# Copy whisper-cli binary if exists
if [ -f "${PROJECT_DIR}/bin/whisper-cli" ]; then
    mkdir -p "${CONTENTS_DIR}/bin"
    cp "${PROJECT_DIR}/bin/whisper-cli" "${CONTENTS_DIR}/bin/"
fi

# Copy models directory if exists
if [ -d "${PROJECT_DIR}/models" ]; then
    cp -r "${PROJECT_DIR}/models" "${RESOURCES_DIR}/"
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
echo "📋 IMPORTANT: To fix Accessibility permissions:"
echo "   1. Open System Settings > Privacy & Security > Accessibility"
echo "   2. Click the '+' button"
echo "   3. Navigate to: ${APP_DIR}"
echo "   4. Add it to the list"
echo ""
echo "🚀 To run: open \"${APP_DIR}\""
