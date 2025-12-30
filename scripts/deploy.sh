#!/bin/bash
set -e

# Configuration
APP_NAME="LocalWhisper"
ROOT_BUILD_DIR="build"
WEB_PUBLIC_DIR="web/public"

# Colors
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Starting Deployment Pipeline...${NC}"

# 1. Run the main build script (build_app.sh)
echo -e "${GREEN}🔨 Running build_app.sh...${NC}"
chmod +x build_app.sh
./build_app.sh

# 2. Verify App Bundle exists
APP_BUNDLE="${ROOT_BUILD_DIR}/${APP_NAME}.app"
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "❌ Error: App bundle not found at ${APP_BUNDLE}"
    exit 1
fi

echo -e "${GREEN}✅ Found App Bundle at ${APP_BUNDLE}${NC}"

# 3. Create DMG (using create_dmg.sh which includes /Applications link)
echo -e "${GREEN}💿 Creating DMG via create_dmg.sh...${NC}"
chmod +x create_dmg.sh
./create_dmg.sh

echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo "File: ${WEB_PUBLIC_DIR}/${APP_NAME}.dmg"
