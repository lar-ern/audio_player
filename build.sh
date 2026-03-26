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
#
# ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=YES is critical for distribution:
# without it the app links against the host macOS Swift runtime, which may
# be a newer version than what ships with the target macOS (e.g. 13.7).
# Embedding the stdlib makes the app self-contained and avoids "image not found"
# crashes on older macOS versions built with Xcode 26+.
xcodebuild \
    -project "$PROJECT" \
    -scheme AudioPlayer \
    -configuration Release \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=YES \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    build

# Re-sign the entire bundle after xcodebuild. This is required when building
# a fat (universal) binary because xcodebuild's per-slice signing is sometimes
# incomplete. --deep ensures nested frameworks (including the embedded Swift
# stdlib dylibs) are all signed with the same ad-hoc identity.
echo "Re-signing bundle (ad-hoc, deep)..."
codesign --deep --force --sign "-" "$BUILD_DIR/$APP_NAME"

echo ""
echo "Build completed: $BUILD_DIR/$APP_NAME"
echo ""
echo "Architecture support:"
lipo -info "$BUILD_DIR/$APP_NAME/Contents/MacOS/AudioPlayer"
echo ""
echo "Swift stdlib embedded:"
ls "$BUILD_DIR/$APP_NAME/Contents/Frameworks/" 2>/dev/null | grep -c "libswift" || echo "  (none — check ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES)"
echo ""
echo "To run on another Mac:"
echo "  1. Remove quarantine if present:  xattr -d com.apple.quarantine \"AudioPlayer.app\""
echo "  2. If Gatekeeper still blocks:    right-click > Open, then click Open in the dialog"
