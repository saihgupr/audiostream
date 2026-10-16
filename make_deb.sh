#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# make_deb.sh — Build AudioStream.app and package it as a rootless .deb
#
# Usage:
#   ./make_deb.sh                        # builds deb in AudioStream/build/
#   ./make_deb.sh --copy-to /path/docs   # also copies the .deb to a repo dir
#
# Requirements: xcodebuild, codesign, ldid, dpkg-deb (or ar+tar fallback)
# ─────────────────────────────────────────────────────────────────────────────

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="AudioStream"
SCHEME_NAME="audiostream"
BUNDLE_ID="com.saihgupr.audiostream"
XCODEPROJ="$PROJECT_ROOT/$PROJECT_NAME.xcodeproj"
ENTITLEMENTS="$PROJECT_ROOT/App/AudioStream.entitlements"
CONTROL_FILE="$PROJECT_ROOT/package/control"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$PROJECT_NAME.xcarchive"

DOCS_DIR="$PROJECT_ROOT/docs"
COPY_TO="$DOCS_DIR"
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --copy-to) COPY_TO="$2"; shift ;;
        *) echo "Usage: ./make_deb.sh [--copy-to /path/to/docs]"; exit 1 ;;
    esac
    shift
done

# ── Read version from control file ───────────────────────────────────────────
VERSION=$(grep "^Version:" "$CONTROL_FILE" | awk '{print $2}')
if [ -z "$VERSION" ]; then
    echo "❌ Could not read Version from $CONTROL_FILE"
    exit 1
fi

DEB_NAME="com.saihgupr.audiostream_${VERSION}_iphoneos-arm64.deb"
DEB_PATH="$BUILD_DIR/$DEB_NAME"

echo "📦 Building AudioStream v$VERSION → $DEB_NAME"

# ── 1. Sync version into Info.plist ──────────────────────────────────────────
echo "🔄 Syncing version $VERSION → Info.plist..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PROJECT_ROOT/App/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PROJECT_ROOT/App/Info.plist"

# ── 2. Archive ────────────────────────────────────────────────────────────────
echo "🏗  Archiving..."
mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH"

xcodebuild archive \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=iOS" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    | grep -E "^(error:|warning:|Build succeeded|\*\* ARCHIVE)" || true

if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "❌ Archive failed — $ARCHIVE_PATH not found"
    exit 1
fi
echo "✅ Archive complete"

# ── 3. Extract .app ───────────────────────────────────────────────────────────
APP_BUNDLE=$(find "$ARCHIVE_PATH/Products/Applications" -name "*.app" -maxdepth 1 | head -n1)
if [ -z "$APP_BUNDLE" ]; then
    echo "❌ No .app found in archive products"
    exit 1
fi
echo "📂 Found bundle: $(basename "$APP_BUNDLE")"

# ── 4. Bundle Swift Concurrency compatibility library (for iOS 14 support) ───
echo "📦 Embedding Swift Concurrency back-deploy library for iOS 14..."
TOOLCHAIN_DIR=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain
SWIFT_CONCURRENCY_DYLIB="$TOOLCHAIN_DIR/usr/lib/swift-5.5/iphoneos/libswift_Concurrency.dylib"

mkdir -p "$APP_BUNDLE/Frameworks"
if [ -f "$SWIFT_CONCURRENCY_DYLIB" ]; then
    cp "$SWIFT_CONCURRENCY_DYLIB" "$APP_BUNDLE/Frameworks/"
    chmod 755 "$APP_BUNDLE/Frameworks/libswift_Concurrency.dylib"
    echo "✅ Bundled libswift_Concurrency.dylib"
else
    echo "⚠️  Warning: libswift_Concurrency.dylib not found at $SWIFT_CONCURRENCY_DYLIB"
fi

BINARY="$APP_BUNDLE/$(basename "${APP_BUNDLE%.app}")"
if [ ! -f "$BINARY" ]; then
    BINARY=$(find "$APP_BUNDLE" -maxdepth 1 -type f -perm +111 | head -n1)
fi

# Change /usr/lib/swift/libswift_Concurrency.dylib reference to @rpath
install_name_tool -change /usr/lib/swift/libswift_Concurrency.dylib @rpath/libswift_Concurrency.dylib "$BINARY" 2>/dev/null || true

# ── 5. Sign with ldid ─────────────────────────────────────────────────────────
echo "🔐 Signing with ldid..."
xattr -cr "$APP_BUNDLE"
if [ -f "$APP_BUNDLE/Frameworks/libswift_Concurrency.dylib" ]; then
    ldid -S "$APP_BUNDLE/Frameworks/libswift_Concurrency.dylib"
fi
ldid -S"$ENTITLEMENTS" "$BINARY"
echo "✅ Signed"

# ── Helper to package a single flavor ─────────────────────────────────────────
pack_flavor() {
    local FLAVOR="$1"           # "rootless" or "rootful"
    local ARCH="$2"             # "iphoneos-arm64" or "iphoneos-arm"
    local INSTALL_DIR="$3"      # "/var/jb/Applications" or "/Applications"
    local FLAVOR_DEB_NAME="com.saihgupr.audiostream_${VERSION}_${ARCH}.deb"
    local FLAVOR_DEB_PATH="$BUILD_DIR/$FLAVOR_DEB_NAME"

    echo "📦 Packaging $FLAVOR ($ARCH) → $FLAVOR_DEB_NAME..."
    local STAGING="$BUILD_DIR/deb_staging_$FLAVOR"
    rm -rf "$STAGING"
    mkdir -p "$STAGING$INSTALL_DIR"
    cp -R "$APP_BUNDLE" "$STAGING$INSTALL_DIR/"

    # Control directory
    local CONTROL_DIR="$STAGING/DEBIAN"
    mkdir -p "$CONTROL_DIR"
    sed "s/^Architecture:.*/Architecture: $ARCH/" "$CONTROL_FILE" > "$CONTROL_DIR/control"

    # Postinst
    cat > "$CONTROL_DIR/postinst" << POSTINST
#!/bin/bash
if [ -d "$INSTALL_DIR/AudioStream.app" ]; then
    chmod -R 755 "$INSTALL_DIR/AudioStream.app"
    uicache -p "$INSTALL_DIR/AudioStream.app" 2>/dev/null || uicache -a 2>/dev/null || true
fi
POSTINST
    chmod 755 "$CONTROL_DIR/postinst"

    # Prerm
    cat > "$CONTROL_DIR/prerm" << 'PRERM'
#!/bin/bash
killall -9 AudioStream 2>/dev/null || true
PRERM
    chmod 755 "$CONTROL_DIR/prerm"

    # Strip all macOS extended attributes (com.apple.provenance, etc.)
    xattr -cr "$STAGING"

    # Archives
    local CONTROL_TAR="$BUILD_DIR/control_$FLAVOR.tar.gz"
    local DATA_TAR="$BUILD_DIR/data_$FLAVOR.tar.gz"
    (cd "$CONTROL_DIR" && COPYFILE_DISABLE=1 tar --format=ustar --no-xattrs --no-mac-metadata -czf "$CONTROL_TAR" .)
    
    # Tar data payload (relative to staging root)
    if [ "$FLAVOR" = "rootless" ]; then
        (cd "$STAGING" && COPYFILE_DISABLE=1 tar --format=ustar --no-xattrs --no-mac-metadata -czf "$DATA_TAR" var)
    else
        (cd "$STAGING" && COPYFILE_DISABLE=1 tar --format=ustar --no-xattrs --no-mac-metadata -czf "$DATA_TAR" Applications)
    fi

    # Assemble debian archive
    python3 - "$FLAVOR_DEB_PATH" "$CONTROL_TAR" "$DATA_TAR" << 'PYEOF'
import sys, os

deb_path, control_tar, data_tar = sys.argv[1], sys.argv[2], sys.argv[3]

def ar_header(name, size):
    return f"{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{size:<10}".encode('ascii') + b"`\n"

with open(deb_path, "wb") as deb:
    deb.write(b"!<arch>\n")
    deb.write(ar_header("debian-binary", 4) + b"2.0\n")
    with open(control_tar, "rb") as f:
        c_bytes = f.read()
    deb.write(ar_header("control.tar.gz", len(c_bytes)) + c_bytes)
    if len(c_bytes) % 2 != 0:
        deb.write(b"\n")
    with open(data_tar, "rb") as f:
        d_bytes = f.read()
    deb.write(ar_header("data.tar.gz", len(d_bytes)) + d_bytes)
    if len(d_bytes) % 2 != 0:
        deb.write(b"\n")
PYEOF

    rm -rf "$STAGING" "$CONTROL_TAR" "$DATA_TAR"
    local DEB_SIZE=$(du -sh "$FLAVOR_DEB_PATH" | awk '{print $1}')
    echo "✅ Built $FLAVOR: $FLAVOR_DEB_PATH ($DEB_SIZE)"

    if [ -n "$COPY_TO" ]; then
        cp "$FLAVOR_DEB_PATH" "$COPY_TO/"
        echo "📂 Copied $FLAVOR_DEB_NAME → $COPY_TO/"
    fi
}

# ── 5. Build Rootless & Rootful Flavors ───────────────────────────────────────
pack_flavor "rootless" "iphoneos-arm64" "/var/jb/Applications"
pack_flavor "rootful"  "iphoneos-arm"   "/Applications"

echo ""
echo "🎉 Done! Both rootless and rootful packages built."
echo "   Rootless: com.saihgupr.audiostream_${VERSION}_iphoneos-arm64.deb"
echo "   Rootful:  com.saihgupr.audiostream_${VERSION}_iphoneos-arm.deb"
echo "   Release files are ready in: $BUILD_DIR/"

