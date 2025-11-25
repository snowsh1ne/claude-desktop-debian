# Flatpak Implementation Plan for Claude Desktop

A simplified plan for packaging Claude Desktop as a Flatpak (X11 only).

---

## 1. Overview

### Goal
Package Claude Desktop as a Flatpak for distribution via Flathub.

### Key Decisions
- **Runtime**: `org.freedesktop.Platform` 25.08 (minimal, standard for Electron)
- **Base**: `org.electronjs.Electron2.BaseApp` (provides Zypak sandbox wrapper)
- **App ID**: `io.github.aaddrick.claude-desktop`
- **Display**: X11 only (no Wayland complexity)

---

## 2. File Structure

```
claude-desktop-debian/
├── flatpak/
│   ├── io.github.aaddrick.claude-desktop.yml   # Manifest
│   ├── io.github.aaddrick.claude-desktop.desktop
│   ├── io.github.aaddrick.claude-desktop.metainfo.xml
│   └── claude-desktop.sh                        # Launch script
├── scripts/
│   └── build-flatpak.sh                         # Build script
└── .github/workflows/
    └── build-flatpak.yml                        # CI workflow
```

---

## 3. Flatpak Manifest

**flatpak/io.github.aaddrick.claude-desktop.yml**

```yaml
app-id: io.github.aaddrick.claude-desktop
runtime: org.freedesktop.Platform
runtime-version: '25.08'
sdk: org.freedesktop.Sdk
base: org.electronjs.Electron2.BaseApp
base-version: '25.08'
command: claude-desktop
separate-locales: false

finish-args:
  # X11 display
  - --share=ipc
  - --socket=x11

  # Audio
  - --socket=pulseaudio

  # Network (required for Claude API)
  - --share=network

  # GPU acceleration
  - --device=dri

  # Config directory
  - --filesystem=~/.config/Claude:create

  # Notifications
  - --talk-name=org.freedesktop.Notifications

  # System tray
  - --talk-name=org.kde.StatusNotifierWatcher

modules:
  - shared-modules/libappindicator/libappindicator-gtk3-12.10.json
  - shared-modules/dbus-glib/dbus-glib.json

  - name: claude-desktop
    buildsystem: simple
    build-commands:
      - mkdir -p /app/lib/electron /app/lib/resources /app/bin
      - mkdir -p /app/share/applications /app/share/metainfo
      - mkdir -p /app/share/icons/hicolor/256x256/apps

      - cp -r electron-dist/* /app/lib/electron/
      - chmod +x /app/lib/electron/electron

      - cp app.asar /app/lib/resources/
      - cp -r app.asar.unpacked /app/lib/resources/

      - install -Dm644 icon.png /app/share/icons/hicolor/256x256/apps/io.github.aaddrick.claude-desktop.png
      - install -Dm755 claude-desktop.sh /app/bin/claude-desktop
      - install -Dm644 io.github.aaddrick.claude-desktop.desktop /app/share/applications/
      - install -Dm644 io.github.aaddrick.claude-desktop.metainfo.xml /app/share/metainfo/

    sources:
      - type: dir
        path: electron-dist
        dest: electron-dist
      - type: file
        path: app.asar
      - type: dir
        path: app.asar.unpacked
      - type: file
        path: icon.png
      - type: file
        path: claude-desktop.sh
      - type: file
        path: io.github.aaddrick.claude-desktop.desktop
      - type: file
        path: io.github.aaddrick.claude-desktop.metainfo.xml

cleanup:
  - /include
  - /lib/pkgconfig
  - '*.la'
  - '*.a'
```

---

## 4. Launch Script

**flatpak/claude-desktop.sh**

```bash
#!/bin/bash
export ELECTRON_FORCE_IS_PACKAGED=true

cd /app/lib/electron
exec zypak-wrapper ./electron \
    /app/lib/resources/app.asar \
    --no-sandbox \
    "$@"
```

---

## 5. Desktop File

**flatpak/io.github.aaddrick.claude-desktop.desktop**

```ini
[Desktop Entry]
Name=Claude Desktop
Comment=Claude AI Desktop Application
Exec=claude-desktop %u
Icon=io.github.aaddrick.claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
```

---

## 6. AppStream Metadata

**flatpak/io.github.aaddrick.claude-desktop.metainfo.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>io.github.aaddrick.claude-desktop</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <name>Claude Desktop</name>
  <summary>AI assistant from Anthropic</summary>
  <description>
    <p>Claude Desktop for Linux. Unofficial port of the Windows application.</p>
  </description>
  <launchable type="desktop-id">io.github.aaddrick.claude-desktop.desktop</launchable>
  <url type="homepage">https://github.com/aaddrick/claude-desktop-debian</url>
  <content_rating type="oars-1.1"/>
  <releases>
    <release version="VERSION" date="DATE"/>
  </releases>
</component>
```

---

## 7. Build Script

**scripts/build-flatpak.sh**

```bash
#!/bin/bash
set -e

VERSION="$1"
ARCH="$2"
WORK_DIR="$3"
APP_STAGING_DIR="$4"

FLATPAK_ID="io.github.aaddrick.claude-desktop"
STAGING="$WORK_DIR/flatpak-staging"
REPO="$WORK_DIR/flatpak-repo"

# Map architecture
[[ "$ARCH" == "amd64" ]] && FLATPAK_ARCH="x86_64" || FLATPAK_ARCH="aarch64"

rm -rf "$STAGING" "$REPO"
mkdir -p "$STAGING"

# Copy files
cp "$APP_STAGING_DIR/app.asar" "$STAGING/"
cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$STAGING/"
cp -r "$APP_STAGING_DIR/node_modules/electron/dist" "$STAGING/electron-dist"
cp "$WORK_DIR/claude_6_256x256x32.png" "$STAGING/icon.png"

# Copy flatpak config files
cp flatpak/claude-desktop.sh "$STAGING/"
cp flatpak/$FLATPAK_ID.desktop "$STAGING/"
cp flatpak/$FLATPAK_ID.metainfo.xml "$STAGING/"

# Update version
sed -i "s/VERSION/$VERSION/g; s/DATE/$(date +%Y-%m-%d)/g" "$STAGING/$FLATPAK_ID.metainfo.xml"

# Clone shared-modules
cd "$STAGING"
git clone --depth=1 https://github.com/flathub/shared-modules.git

# Copy manifest
cp "$OLDPWD/flatpak/$FLATPAK_ID.yml" .

# Build
flatpak-builder --arch="$FLATPAK_ARCH" --force-clean --repo="$REPO" build "$FLATPAK_ID.yml"

# Bundle
flatpak build-bundle "$REPO" "$WORK_DIR/claude-desktop-$VERSION-$ARCH.flatpak" "$FLATPAK_ID"

echo "Created: $WORK_DIR/claude-desktop-$VERSION-$ARCH.flatpak"
```

---

## 8. Add to build.sh

Add `flatpak` option:

```bash
# In validation:
if [[ "$BUILD_FORMAT" != "deb" && "$BUILD_FORMAT" != "appimage" && "$BUILD_FORMAT" != "flatpak" ]]; then
    echo "Invalid build format. Must be: deb, appimage, or flatpak"
    exit 1
fi

# In build section:
elif [ "$BUILD_FORMAT" = "flatpak" ]; then
    chmod +x scripts/build-flatpak.sh
    scripts/build-flatpak.sh "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR"
fi
```

---

## 9. GitHub Workflow

**.github/workflows/build-flatpak.yml**

```yaml
name: Build Flatpak

on:
  workflow_call:
    inputs:
      architecture:
        required: true
        type: string

jobs:
  build:
    runs-on: ${{ inputs.architecture == 'arm64' && 'ubuntu-22.04-arm' || 'ubuntu-latest' }}
    steps:
      - uses: actions/checkout@v4

      - name: Install Flatpak
        run: |
          sudo apt-get update
          sudo apt-get install -y flatpak flatpak-builder
          flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
          flatpak install --user -y flathub org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08
          flatpak install --user -y flathub org.electronjs.Electron2.BaseApp//25.08

      - name: Build
        run: |
          chmod +x ./build.sh
          ./build.sh --build flatpak

      - uses: actions/upload-artifact@v4
        with:
          name: flatpak-${{ inputs.architecture }}
          path: claude-desktop-*.flatpak
```

---

## 10. Implementation Steps

1. Create `flatpak/` directory with 4 files (manifest, desktop, metainfo, launch script)
2. Create `scripts/build-flatpak.sh`
3. Add `flatpak` option to `build.sh`
4. Create GitHub workflow
5. Test locally: `./build.sh --build flatpak`
6. Submit to Flathub

---

## 11. Local Testing

```bash
# Build
./build.sh --build flatpak

# Install
flatpak install --user ./claude-desktop-*.flatpak

# Run
flatpak run io.github.aaddrick.claude-desktop

# Uninstall
flatpak uninstall io.github.aaddrick.claude-desktop
```

---

## Key Points

- **Zypak** handles Chromium sandbox inside Flatpak sandbox
- **libappindicator** provides system tray support
- **X11 only** - simpler, avoids Wayland portal complexity
- **~/.config/Claude** accessible for MCP configuration
- Reuses existing app.asar patching from build.sh
