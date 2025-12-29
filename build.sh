#!/bin/bash

# Build script for AudioPlayer macOS app
# Usage: ./build.sh

set -e

echo "Building AudioPlayer..."

# Project configuration
PROJECT_NAME="AudioPlayer"
BUILD_DIR="build"
APP_NAME="AudioPlayer.app"

# Create build directory
mkdir -p "$BUILD_DIR"

# Compile Swift files
swiftc -o "$BUILD_DIR/$PROJECT_NAME" \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework Foundation \
    -target arm64-apple-macos13.0 \
    AudioPlayer/*.swift

echo "Build completed: $BUILD_DIR/$PROJECT_NAME"
echo ""
echo "Note: This creates a command-line executable."
echo "For a proper macOS GUI app, please use Xcode."
echo ""
echo "To create a full .app bundle, use Xcode:"
echo "1. Open Xcode"
echo "2. Create new macOS App project"
echo "3. Add the Swift files"
echo "4. Build (Cmd+B) and Run (Cmd+R)"
