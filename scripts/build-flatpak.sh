#!/bin/bash
set -e

# Arguments passed from the main script
VERSION="$1"
ARCHITECTURE="$2"
WORK_DIR="$3"
APP_STAGING_DIR="$4"
PACKAGE_NAME="$5"

echo "--- Starting Flatpak Package Build ---"
echo "Version: $VERSION"
echo "Architecture: $ARCHITECTURE"
echo "Work Directory: $WORK_DIR"
echo "App Staging Directory: $APP_STAGING_DIR"
echo "Package Name: $PACKAGE_NAME"

FLATPAK_ID="io.github.aaddrick.claude-desktop"
STAGING="$WORK_DIR/flatpak-staging"
REPO="$WORK_DIR/flatpak-repo"
BUILD_DIR="$WORK_DIR/flatpak-build"
PROJECT_ROOT="$(dirname "$(dirname "$(realpath "$0")")")"

# Map architecture
case "$ARCHITECTURE" in
    "amd64") FLATPAK_ARCH="x86_64" ;;
    "arm64") FLATPAK_ARCH="aarch64" ;;
    *) echo "Unsupported architecture: $ARCHITECTURE"; exit 1 ;;
esac

echo "Flatpak architecture: $FLATPAK_ARCH"

# Clean previous builds
rm -rf "$STAGING" "$REPO" "$BUILD_DIR"
mkdir -p "$STAGING"

# --- Copy application files ---
echo "Copying application files to staging..."

# Copy app.asar
cp "$APP_STAGING_DIR/app.asar" "$STAGING/"
cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$STAGING/"

# Copy Electron distribution
if [ -d "$APP_STAGING_DIR/node_modules/electron/dist" ]; then
    cp -r "$APP_STAGING_DIR/node_modules/electron/dist" "$STAGING/electron-dist"
    echo "Copied Electron distribution"
else
    echo "ERROR: Electron distribution not found at $APP_STAGING_DIR/node_modules/electron/dist"
    exit 1
fi

# --- Prepare icons ---
echo "Preparing icons..."
ICONS_DIR="$STAGING/icons"
mkdir -p "$ICONS_DIR"

# Map icon files from the extracted Windows icons
declare -A icon_files=(
    ["256x256"]="claude_6_256x256x32.png"
    ["64x64"]="claude_7_64x64x32.png"
    ["48x48"]="claude_8_48x48x32.png"
    ["32x32"]="claude_10_32x32x32.png"
    ["16x16"]="claude_13_16x16x32.png"
)

for size in "${!icon_files[@]}"; do
    src_file="$WORK_DIR/${icon_files[$size]}"
    if [ -f "$src_file" ]; then
        cp "$src_file" "$ICONS_DIR/${size}.png"
        echo "Copied icon: ${size}.png"
    else
        echo "Warning: Icon not found: $src_file"
    fi
done

# --- Copy Flatpak configuration files ---
echo "Copying Flatpak configuration files..."

cp "$PROJECT_ROOT/flatpak/claude-desktop.sh" "$STAGING/"
cp "$PROJECT_ROOT/flatpak/$FLATPAK_ID.desktop" "$STAGING/"
cp "$PROJECT_ROOT/flatpak/$FLATPAK_ID.metainfo.xml" "$STAGING/"

# Update version in metainfo
sed -i "s/VERSION/$VERSION/g" "$STAGING/$FLATPAK_ID.metainfo.xml"
sed -i "s/DATE/$(date +%Y-%m-%d)/g" "$STAGING/$FLATPAK_ID.metainfo.xml"

# --- Clone shared-modules ---
echo "Cloning shared-modules..."
cd "$STAGING"
if [ ! -d "shared-modules" ]; then
    if ! git clone --depth=1 https://github.com/flathub/shared-modules.git; then
        echo "ERROR: Failed to clone shared-modules repository"
        exit 1
    fi
fi

# Verify shared-modules files exist
if [ ! -f "shared-modules/libappindicator/libappindicator-gtk3-12.10.json" ]; then
    echo "ERROR: Required shared-modules file not found: libappindicator-gtk3-12.10.json"
    exit 1
fi
if [ ! -f "shared-modules/dbus-glib/dbus-glib.json" ]; then
    echo "ERROR: Required shared-modules file not found: dbus-glib.json"
    exit 1
fi
echo "✓ shared-modules cloned and verified"

# --- Copy manifest ---
cp "$PROJECT_ROOT/flatpak/$FLATPAK_ID.yml" "$STAGING/"

# --- Verify Flatpak runtimes ---
echo "Verifying Flatpak runtimes are available..."

# Add flathub remote if not present (needed for local builds)
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true

# Check if runtimes are installed (CI installs them in workflow, local builds may need to install)
if ! flatpak info --user org.freedesktop.Platform//24.08 &>/dev/null; then
    echo "Installing Flatpak runtimes (this may take a while on first run)..."
    flatpak install --user -y --noninteractive flathub org.freedesktop.Platform//24.08 || true
    flatpak install --user -y --noninteractive flathub org.freedesktop.Sdk//24.08 || true
    flatpak install --user -y --noninteractive flathub org.electronjs.Electron2.BaseApp//24.08 || true
else
    echo "✓ Flatpak runtimes already installed"
fi

# --- Build Flatpak ---
echo "Building Flatpak..."
cd "$STAGING"

flatpak-builder \
    --user \
    --arch="$FLATPAK_ARCH" \
    --force-clean \
    --repo="$REPO" \
    --install-deps-from=flathub \
    "$BUILD_DIR" \
    "$FLATPAK_ID.yml"

# --- Create bundle ---
echo "Creating Flatpak bundle..."
BUNDLE_FILE="$WORK_DIR/${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.flatpak"

flatpak build-bundle \
    --arch="$FLATPAK_ARCH" \
    "$REPO" \
    "$BUNDLE_FILE" \
    "$FLATPAK_ID"

echo "--- Flatpak Package Build Finished ---"
echo "Bundle created: $BUNDLE_FILE"

exit 0
