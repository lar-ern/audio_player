#!/bin/bash

# Build script for AudioPlayer macOS app
# Usage: ./build.sh
#
# Produces a universal binary that runs on both Apple Silicon (arm64)
# and Intel (x86_64) Macs.

set -e

echo "Building AudioPlayer..."

# Project configuration
PROJECT_NAME="AudioPlayer"
BUILD_DIR="build"
APP_NAME="AudioPlayer.app"

SWIFT_FILES=AudioPlayer/AudioPlayer/*.swift

# Create build directory
mkdir -p "$BUILD_DIR"

# Compile for Apple Silicon (arm64)
echo "  Compiling for arm64 (Apple Silicon)..."
swiftc -o "$BUILD_DIR/${PROJECT_NAME}_arm64" \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework Foundation \
    -target arm64-apple-macos13.0 \
    $SWIFT_FILES

# Compile for Intel (x86_64)
echo "  Compiling for x86_64 (Intel)..."
swiftc -o "$BUILD_DIR/${PROJECT_NAME}_x86_64" \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework Foundation \
    -target x86_64-apple-macos13.0 \
    $SWIFT_FILES

# Combine into a universal binary
echo "  Creating universal binary..."
lipo -create \
    "$BUILD_DIR/${PROJECT_NAME}_arm64" \
    "$BUILD_DIR/${PROJECT_NAME}_x86_64" \
    -output "$BUILD_DIR/$PROJECT_NAME"

# Clean up intermediate single-arch binaries
rm "$BUILD_DIR/${PROJECT_NAME}_arm64" "$BUILD_DIR/${PROJECT_NAME}_x86_64"

echo "Build completed: $BUILD_DIR/$PROJECT_NAME"
echo ""
echo "Architecture support:"
lipo -info "$BUILD_DIR/$PROJECT_NAME"
echo ""
echo "Note: This creates a command-line executable."
echo "For a proper macOS GUI app, please use Xcode."
echo ""
echo "To create a full .app bundle, use Xcode:"
echo "1. Open AudioPlayer/AudioPlayer/AudioPlayer.xcodeproj"
echo "2. Set deployment target to macOS 13.0"
echo "3. Build (Cmd+B) and Run (Cmd+R)"
