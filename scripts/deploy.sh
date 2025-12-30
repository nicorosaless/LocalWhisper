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

# 1. Run the main build script (scripts/build.sh)
echo -e "${GREEN}🔨 Running scripts/build.sh...${NC}"
chmod +x scripts/build.sh
./scripts/build.sh

# 2. Verify App Bundle exists
APP_BUNDLE="${ROOT_BUILD_DIR}/${APP_NAME}.app"
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "❌ Error: App bundle not found at ${APP_BUNDLE}"
    exit 1
fi

echo -e "${GREEN}✅ Found App Bundle at ${APP_BUNDLE}${NC}"

# 3. Create DMG (using scripts/create_dmg.sh)
echo -e "${GREEN}💿 Creating DMG via scripts/create_dmg.sh...${NC}"
chmod +x scripts/create_dmg.sh
./scripts/create_dmg.sh

echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo "File: ${WEB_PUBLIC_DIR}/${APP_NAME}.dmg"
