#!/bin/bash
#
# build_native.sh — Build AudioPlayer using swiftc directly.
#
# Use this script when building on a Mac where the installed Xcode is older
# than the Xcode version used to create the project (e.g. Xcode 15 on an
# Intel Mac running macOS 13.7).  It bypasses the Xcode project file entirely
# and calls the Swift compiler directly, so it works with any Xcode / Swift
# version that supports macOS 13 deployment.
#
# Usage:
#   chmod +x build_native.sh
#   ./build_native.sh
#
# Output: build/AudioPlayer.app

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/AudioPlayer"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="AudioPlayer.app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME"
BINARY="$APP_BUNDLE/Contents/MacOS/AudioPlayer"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"

# ---------------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------------
SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)
if [ -z "$SDK" ]; then
    echo "ERROR: Could not locate macOS SDK. Make sure Xcode is installed and"
    echo "       'xcode-select -p' points to a valid Xcode installation."
    exit 1
fi

SWIFT=$(xcrun -f swiftc 2>/dev/null)
if [ -z "$SWIFT" ]; then
    echo "ERROR: swiftc not found. Install Xcode or the Command Line Tools."
    exit 1
fi

SWIFT_VERSION=$("$SWIFT" --version 2>&1 | head -1)
echo "Using: $SWIFT_VERSION"
echo "SDK:   $SDK"
echo ""

# ---------------------------------------------------------------------------
# Source files
# ---------------------------------------------------------------------------
SOURCES=(
    "$SRC_DIR/AudioPlayerApp.swift"
    "$SRC_DIR/AudioPlayerManager.swift"
    "$SRC_DIR/ContentView.swift"
    "$SRC_DIR/FLACDecoder.swift"
)

for f in "${SOURCES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Source file not found: $f"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Clean & prepare bundle skeleton
# ---------------------------------------------------------------------------
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$FRAMEWORKS_DIR"

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------
echo "Compiling Swift sources..."

# Detect host architecture to decide whether to build universal or native-only.
HOST_ARCH=$(uname -m)   # arm64 or x86_64

if [ "$HOST_ARCH" = "x86_64" ]; then
    # On Intel: build x86_64 only (native).  A universal build requires an
    # arm64 capable host or cross-compilation support in the installed SDK.
    TARGET="x86_64-apple-macos13.0"
    echo "Host: Intel x86_64 — building native x86_64 binary"
else
    # On Apple Silicon: attempt universal build.
    TARGET="arm64-apple-macos13.0"
    echo "Host: Apple Silicon arm64 — building universal binary"
fi

# Build flags common to both paths
COMMON_FLAGS=(
    -sdk "$SDK"
    -target "$TARGET"
    -O
    -module-name AudioPlayer
    -framework SwiftUI
    -framework AVFoundation
    -framework AppKit
    -framework Foundation
    -Xfrontend -disable-reflection-metadata   # smaller binary; not needed at runtime
    -o "$BINARY"
)

# Remove -disable-reflection-metadata if the compiler doesn't support it
# (older swiftc will error; catch and retry without it)
if ! "$SWIFT" "${COMMON_FLAGS[@]}" "${SOURCES[@]}" 2>/dev/null; then
    echo "(retrying without -disable-reflection-metadata...)"
    COMMON_FLAGS=("${COMMON_FLAGS[@]//-Xfrontend/}")
    COMMON_FLAGS=("${COMMON_FLAGS[@]//-disable-reflection-metadata/}")
    "$SWIFT" "${COMMON_FLAGS[@]}" "${SOURCES[@]}"
fi

# On Apple Silicon host: also compile an x86_64 slice and lipo them together
if [ "$HOST_ARCH" != "x86_64" ]; then
    echo "Compiling x86_64 slice..."
    X86_BINARY="$BUILD_DIR/AudioPlayer_x86_64"
    X86_FLAGS=(
        -sdk "$SDK"
        -target "x86_64-apple-macos13.0"
        -O
        -module-name AudioPlayer
        -framework SwiftUI
        -framework AVFoundation
        -framework AppKit
        -framework Foundation
        -o "$X86_BINARY"
    )
    "$SWIFT" "${X86_FLAGS[@]}" "${SOURCES[@]}"

    echo "Creating fat binary..."
    ARM_BINARY="$BUILD_DIR/AudioPlayer_arm64"
    cp "$BINARY" "$ARM_BINARY"
    lipo -create "$ARM_BINARY" "$X86_BINARY" -output "$BINARY"
    rm "$ARM_BINARY" "$X86_BINARY"
fi

# ---------------------------------------------------------------------------
# Info.plist
# ---------------------------------------------------------------------------
INFOPLIST_SRC="$SRC_DIR/Info.plist"
INFOPLIST_DST="$APP_BUNDLE/Contents/Info.plist"

# Merge the project Info.plist with mandatory keys that are normally injected
# by Xcode's GENERATE_INFOPLIST_FILE mechanism.
python3 - <<PYEOF
import plistlib, sys, os

src = "$INFOPLIST_SRC"
dst = "$INFOPLIST_DST"

with open(src, "rb") as f:
    data = plistlib.load(f)

# Keys Xcode normally auto-generates from build settings
data.setdefault("CFBundleName",             "AudioPlayer")
data.setdefault("CFBundleDisplayName",      "AudioPlayer")
data.setdefault("CFBundleIdentifier",       "EDEES.AudioPlayer")
data.setdefault("CFBundleVersion",          "1")
data.setdefault("CFBundleShortVersionString","1.0")
data.setdefault("CFBundleExecutable",       "AudioPlayer")
data.setdefault("CFBundlePackageType",      "APPL")
data.setdefault("CFBundleSignature",        "????")
data.setdefault("NSPrincipalClass",         "NSApplication")
data.setdefault("NSHighResolutionCapable",  True)
data.setdefault("CFBundleSupportedPlatforms", ["MacOSX"])
data.setdefault("LSMinimumSystemVersion",   "13.0")

with open(dst, "wb") as f:
    plistlib.dump(data, f)

print("Info.plist written to", dst)
PYEOF

# ---------------------------------------------------------------------------
# Embed Swift standard libraries
# ---------------------------------------------------------------------------
# Embedding the Swift stdlib makes the app self-contained: it no longer
# depends on the macOS system Swift runtime, which may be older than the
# version used to compile the app.
echo "Embedding Swift standard libraries..."
TOOLCHAIN_DIR=$(dirname "$(dirname "$SWIFT")")
SWIFT_LIB_DIR="$TOOLCHAIN_DIR/lib/swift/macosx"

if [ -d "$SWIFT_LIB_DIR" ]; then
    # Copy Swift dylibs needed at runtime
    SWIFT_DYLIBS=(
        libswiftCore.dylib
        libswiftDarwin.dylib
        libswiftCoreFoundation.dylib
        libswiftFoundation.dylib
        libswiftAppKit.dylib
        libswiftObjectiveC.dylib
        libswiftDispatch.dylib
        libswiftCoreGraphics.dylib
        libswiftXPC.dylib
        libswiftIOKit.dylib
        libswiftCoreImage.dylib
        libswiftMetal.dylib
        libswiftQuartzCore.dylib
        libswiftSwiftUI.dylib
    )
    for dylib in "${SWIFT_DYLIBS[@]}"; do
        if [ -f "$SWIFT_LIB_DIR/$dylib" ]; then
            cp "$SWIFT_LIB_DIR/$dylib" "$FRAMEWORKS_DIR/"
        fi
    done

    # Also copy any other libswift*.dylib files present
    for f in "$SWIFT_LIB_DIR"/libswift*.dylib; do
        [ -f "$f" ] && cp -n "$f" "$FRAMEWORKS_DIR/" 2>/dev/null || true
    done

    EMBEDDED=$(ls "$FRAMEWORKS_DIR" | wc -l | tr -d ' ')
    echo "Embedded $EMBEDDED Swift dylib(s)"

    # Update the binary's rpath to find the embedded dylibs
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY" 2>/dev/null || true
else
    echo "WARNING: Swift lib dir not found at $SWIFT_LIB_DIR"
    echo "         The app may not run on macOS versions with an older Swift runtime."
fi

# ---------------------------------------------------------------------------
# Ad-hoc code signing
# ---------------------------------------------------------------------------
echo "Signing bundle (ad-hoc)..."
# Sign frameworks first, then the main binary, then the bundle
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] && codesign --force --sign "-" "$dylib" 2>/dev/null || true
done
codesign --force --sign "-" "$BINARY"
codesign --deep --force --sign "-" "$APP_BUNDLE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Build complete: $APP_BUNDLE"
echo ""
echo "Architecture:"
lipo -info "$BINARY"
echo ""
echo "Swift libs embedded: $(ls "$FRAMEWORKS_DIR" 2>/dev/null | grep -c libswift || echo 0)"
echo ""
echo "To run on another Mac:"
echo "  1. Copy AudioPlayer.app to the target Mac"
echo "  2. Remove quarantine if present:"
echo "       xattr -d com.apple.quarantine AudioPlayer.app"
echo "  3. If Gatekeeper still blocks: right-click > Open, then click Open"
