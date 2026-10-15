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

COPY_TO=""
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

# ── 4. Sign with ldid ─────────────────────────────────────────────────────────
echo "🔐 Signing with ldid..."
xattr -cr "$APP_BUNDLE"
# ldid -S<entitlements> <binary>
BINARY="$APP_BUNDLE/$(basename "${APP_BUNDLE%.app}")"
# The binary name may differ from the .app name due to PRODUCT_NAME
if [ ! -f "$BINARY" ]; then
    BINARY=$(find "$APP_BUNDLE" -maxdepth 1 -type f -perm +111 | head -n1)
fi
ldid -S"$ENTITLEMENTS" "$BINARY"
echo "✅ Signed"

# ── 5. Build .deb layout ──────────────────────────────────────────────────────
echo "📦 Assembling .deb layout..."
STAGING="$BUILD_DIR/deb_staging"
rm -rf "$STAGING"

# Rootless path: /var/jb/Applications/
APP_INSTALL_DIR="$STAGING/var/jb/Applications"
mkdir -p "$APP_INSTALL_DIR"
cp -R "$APP_BUNDLE" "$APP_INSTALL_DIR/"

# Control
CONTROL_DIR="$STAGING/DEBIAN"
mkdir -p "$CONTROL_DIR"
cp "$CONTROL_FILE" "$CONTROL_DIR/control"

# Post-install: register with uicache
cat > "$CONTROL_DIR/postinst" << 'POSTINST'
#!/bin/bash
if [ -d /var/jb/Applications/AudioStream.app ]; then
    uicache -p /var/jb/Applications/AudioStream.app 2>/dev/null || true
fi
POSTINST
chmod 755 "$CONTROL_DIR/postinst"

# Pre-remove: kill running instance
cat > "$CONTROL_DIR/prerm" << 'PRERM'
#!/bin/bash
killall -9 AudioStream 2>/dev/null || true
PRERM
chmod 755 "$CONTROL_DIR/prerm"

# ── 6. Package ────────────────────────────────────────────────────────────────
echo "🔨 Running dpkg-deb..."
rm -f "$DEB_PATH"

if command -v dpkg-deb &>/dev/null; then
    dpkg-deb -Zgzip -b "$STAGING" "$DEB_PATH"
else
    echo "📦 Packaging deb archive using python3..."

    # control.tar.gz (archive files directly inside DEBIAN directory)
    CONTROL_TAR="$BUILD_DIR/control.tar.gz"
    (cd "$CONTROL_DIR" && COPYFILE_DISABLE=1 tar -czf "$CONTROL_TAR" .)

    # data.tar.gz (everything in staging except DEBIAN)
    DATA_TAR="$BUILD_DIR/data.tar.gz"
    (cd "$STAGING" && COPYFILE_DISABLE=1 tar -czf "$DATA_TAR" var)

    # Assemble debian archive: debian-binary, control.tar.gz, data.tar.gz
    python3 - "$DEB_PATH" "$CONTROL_TAR" "$DATA_TAR" << 'PYEOF'
import sys, os

deb_path, control_tar, data_tar = sys.argv[1], sys.argv[2], sys.argv[3]

def ar_header(name, size):
    return f"{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{size:<10}".encode('ascii') + b"`\n"

with open(deb_path, "wb") as deb:
    deb.write(b"!<arch>\n")
    # 1. debian-binary
    deb.write(ar_header("debian-binary", 4) + b"2.0\n")
    # 2. control.tar.gz
    with open(control_tar, "rb") as f:
        c_bytes = f.read()
    deb.write(ar_header("control.tar.gz", len(c_bytes)) + c_bytes)
    if len(c_bytes) % 2 != 0:
        deb.write(b"\n")
    # 3. data.tar.gz
    with open(data_tar, "rb") as f:
        d_bytes = f.read()
    deb.write(ar_header("data.tar.gz", len(d_bytes)) + d_bytes)
    if len(d_bytes) % 2 != 0:
        deb.write(b"\n")
PYEOF

    rm -f "$CONTROL_TAR" "$DATA_TAR"
fi

rm -rf "$STAGING"

if [ ! -f "$DEB_PATH" ]; then
    echo "❌ .deb packaging failed"
    exit 1
fi

DEB_SIZE=$(du -sh "$DEB_PATH" | awk '{print $1}')
echo "✅ Built: $DEB_PATH ($DEB_SIZE)"

# ── 7. Optionally copy to repo docs/ ─────────────────────────────────────────
if [ -n "$COPY_TO" ]; then
    if [ ! -d "$COPY_TO" ]; then
        echo "❌ --copy-to target not found: $COPY_TO"
        exit 1
    fi
    cp "$DEB_PATH" "$COPY_TO/"
    echo "📂 Copied $DEB_NAME → $COPY_TO/"
fi

echo ""
echo "🎉 Done! $DEB_NAME"
echo "   To push to repo: ./make_deb.sh --copy-to ../RemoteCompanion/docs"
echo "   Then run:        cd ../RemoteCompanion && ./repo_utils/update_repo.sh"
