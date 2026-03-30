#!/bin/bash

# Exit on error
set -e

# Set up colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get version from Info.plist or use default
VERSION=$(defaults read "$(pwd)/AutoSRT/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
BUILD_NUMBER=$(defaults read "$(pwd)/AutoSRT/Info.plist" CFBundleVersion 2>/dev/null || echo "1")

echo -e "${GREEN}🚀 Building AutoSRT ${VERSION} (${BUILD_NUMBER})...${NC}"

rm -rf build
echo -e "${BLUE}🧹 Clean build directory...${NC}"

# Clean derived data to ensure a fresh build
rm -rf ~/Library/Developer/Xcode/DerivedData

# Build for Apple Silicon (arm64)
echo -e "${BLUE}🔨 Building for Apple Silicon (arm64)...${NC}"
xcodebuild -project AutoSRT.xcodeproj -scheme AutoSRT -configuration Release \
  -derivedDataPath build/arm64 \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO 

xattr -cr build/arm64/Build/Products/Release/AutoSRT.app

codesign --force --deep --timestamp \
  --sign "autosrt2025" \
  build/arm64/Build/Products/Release/AutoSRT.app

codesign --verify --deep --strict --verbose build/arm64/Build/Products/Release/AutoSRT.app

# Set up variables
APP_NAME="AutoSRT"
DMG_NAME="build/${APP_NAME}-${VERSION}-${BUILD_NUMBER}.dmg"
TMP_DMG="build/tmp.dmg"
VOLUME_NAME="${APP_NAME}"
APP_PATH="build/arm64/Build/Products/Release/${APP_NAME}.app"
BINARY_NAME="AutoSRT"

# Copy the app to the build directory
echo -e "${BLUE}📦 Copying app to build directory...${NC}"
mkdir -p "build/dmg"
cp -R "${APP_PATH}" "build/dmg/"

# Remove any debug dylibs that might cause issues
echo -e "${BLUE}🧹 Removing debug dylibs...${NC}"
find "build/dmg/${APP_NAME}.app" -name "*.debug.dylib" -delete

# Get app size and add margin for resources
APP_SIZE=$(du -sm "$APP_PATH" | cut -f1)
DMG_SIZE=$((APP_SIZE + 1000))
echo "📊 App size: ${APP_SIZE}MB, DMG size: ${DMG_SIZE}MB"

# Create DMG
echo "💿 Creating DMG..."
hdiutil create -size "${DMG_SIZE}m" -fs HFS+ -volname "$VOLUME_NAME" "$TMP_DMG"

# Mount the temporary DMG
echo -e "${BLUE}📀 Mounting DMG...${NC}"
MOUNT_POINT=$(hdiutil attach -nobrowse -noverify "$TMP_DMG" | grep Apple_HFS | cut -f 3)
echo "Mounted at: $MOUNT_POINT"

# Wait for mount and verify
sleep 2

if [ -z "$MOUNT_POINT" ]; then
    echo -e "${RED}❌ Failed to mount DMG${NC}"
    exit 1
fi

# Copy the app
echo -e "${BLUE}📦 Copying application...${NC}"
cp -Rv "$APP_PATH" "$MOUNT_POINT/"

# Copy install.txt
echo -e "${BLUE}📝 Copying install.txt...${NC}"
cp -Rv "install.txt" "$MOUNT_POINT/"

# Copy Home.webloc
echo -e "${BLUE}📦 Copying Home.webloc...${NC}"
cp -Rv "Home.webloc" "$MOUNT_POINT/"

# Copy AIClips.webloc
echo -e "${BLUE}📦 Copying AIClips.webloc...${NC}"
cp -Rv "AIClips.webloc" "$MOUNT_POINT/"

# Create Applications symlink
echo -e "${BLUE}🔗 Creating Applications symlink...${NC}"
ln -s /Applications "$MOUNT_POINT/Applications"

# Unmount the temporary DMG
echo -e "${BLUE}💿 Unmounting DMG...${NC}"
hdiutil detach "$MOUNT_POINT"

# Convert the temporary DMG to the final compressed DMG
echo -e "${BLUE}🗜️ Compressing DMG...${NC}"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"

# Clean up
rm -f "$TMP_DMG"

echo -e "${GREEN}✅ ARM64 DMG created successfully at $DMG_NAME (version $VERSION build $BUILD_NUMBER)${NC}"

# Verify architectures
echo -e "${BLUE}🔍 Verifying supported architectures...${NC}"
lipo -info "$APP_PATH/Contents/MacOS/$BINARY_NAME"

######################