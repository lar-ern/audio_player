#!/bin/bash

# Build script for AudioPlayer macOS app
# Usage: ./build.sh
#
# Produces a universal .app bundle that runs on both Apple Silicon (arm64)
# and Intel (x86_64) Macs running macOS 13.0+.
#
# NOTE: Do NOT use Xcode's Cmd+B to build for distribution — it only builds
# for the host architecture. Use this script or Product > Archive in Xcode.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/AudioPlayer/AudioPlayer/AudioPlayer.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="AudioPlayer.app"

echo "Building AudioPlayer (universal binary)..."

# Clean previous build output
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build using xcodebuild with explicit arch flags.
# ONLY_ACTIVE_ARCH=NO and ARCHS override are required — without them Xcode
# silently builds only for the host machine's architecture (arm64 on Apple
# Silicon) even when the project settings say otherwise.
xcodebuild \
    -project "$PROJECT" \
    -scheme AudioPlayer \
    -configuration Release \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    build

echo ""
echo "Build completed: $BUILD_DIR/$APP_NAME"
echo ""
echo "Architecture support:"
lipo -info "$BUILD_DIR/$APP_NAME/Contents/MacOS/AudioPlayer"
echo ""
echo "To run on another Mac, first remove the quarantine flag:"
echo "  xattr -d com.apple.quarantine \"$BUILD_DIR/$APP_NAME\""
