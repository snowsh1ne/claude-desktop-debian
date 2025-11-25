# Flatpak Implementation Plan for Claude Desktop

This document provides a comprehensive plan for implementing Claude Desktop as a Flatpak package, based on in-depth research of Flatpak runtimes, Electron packaging best practices, and analysis of the existing repository.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Flatpak Runtime Analysis](#2-flatpak-runtime-analysis)
3. [Technical Architecture](#3-technical-architecture)
4. [Implementation Phases](#4-implementation-phases)
5. [File Structure](#5-file-structure)
6. [Flatpak Manifest Design](#6-flatpak-manifest-design)
7. [Build Script Modifications](#7-build-script-modifications)
8. [GitHub Workflow Integration](#8-github-workflow-integration)
9. [Flathub Submission Process](#9-flathub-submission-process)
10. [Testing Strategy](#10-testing-strategy)
11. [Known Challenges and Solutions](#11-known-challenges-and-solutions)
12. [Appendix: Reference Implementations](#12-appendix-reference-implementations)

---

## 1. Executive Summary

### Goal
Package Claude Desktop as a Flatpak application for distribution via Flathub and direct installation, providing users with a sandboxed, distribution-agnostic installation option.

### Why Flatpak?
- **Distribution Independence**: Works on any Linux distribution with Flatpak support
- **Sandboxed Security**: Applications run isolated from the host system
- **Automatic Updates**: Flathub provides automatic update mechanisms
- **Consistent Dependencies**: Runtime provides all needed libraries
- **User Trust**: Flathub is a widely trusted source for Linux applications

### Scope
- Create a Flatpak manifest for Claude Desktop
- Add `--build flatpak` option to existing `build.sh`
- Create dedicated `scripts/build-flatpak.sh` script
- Implement GitHub Actions workflow for Flatpak builds
- Prepare for Flathub submission

---

## 2. Flatpak Runtime Analysis

### 2.1 Available Runtimes

| Runtime | Base | Best For | Package Count |
|---------|------|----------|---------------|
| **org.freedesktop.Platform** | None | Minimal apps, Electron | Core system libraries only |
| **org.gnome.Platform** | Freedesktop | GTK/GNOME apps | + GTK, GLib, GNOME libs |
| **org.kde.Platform** | Freedesktop | Qt/KDE apps | + Qt, KDE Frameworks |
| **io.elementary.Platform** | GNOME | elementary OS apps | + elementary libs |

### 2.2 Recommended Runtime: Freedesktop

For Claude Desktop (Electron-based), **org.freedesktop.Platform** is the optimal choice:

**Reasons:**
1. **Minimal footprint** - Electron bundles its own Chromium; no need for GTK/Qt
2. **Standard practice** - Discord, Slack, Spotify all use Freedesktop runtime
3. **Electron BaseApp compatibility** - `org.electronjs.Electron2.BaseApp` is built on Freedesktop
4. **Faster updates** - Freedesktop runtime updates are more frequent

**Runtime Version:** `25.08` (current stable, released August 2025)

### 2.3 What Freedesktop Runtime Provides

```
Core Libraries:
- glibc, glib2, libX11, libxcb
- Wayland libraries
- PulseAudio/PipeWire audio
- OpenGL/Mesa graphics stack
- D-Bus for IPC
- fontconfig, freetype
- SSL/TLS (OpenSSL)
- zlib compression

Development Tools (SDK only):
- GCC compiler
- pkg-config
- Python 3
- Meson/CMake build systems
```

### 2.4 What Electron BaseApp Adds

The `org.electronjs.Electron2.BaseApp` provides:

```
Additional Components:
- Zypak (Chromium sandbox wrapper)
- libsecret (credential storage)
- libgnome-keyring (legacy keyring)
- libappindicator (system tray)
- dbus-glib (D-Bus bindings)
- speech-dispatcher (Web Speech API)
- asarPy (asar archive handling)
```

---

## 3. Technical Architecture

### 3.1 Flatpak Sandbox Model

```
┌─────────────────────────────────────────────────────────────────┐
│                         HOST SYSTEM                              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    FLATPAK SANDBOX                          │ │
│  │  ┌─────────────────────────────────────────────────────┐   │ │
│  │  │              Claude Desktop App                      │   │ │
│  │  │  ┌─────────────┐  ┌────────────────────────────┐   │   │ │
│  │  │  │ Electron    │  │ app.asar (patched)         │   │   │ │
│  │  │  │ (bundled)   │  │ - frame-fix-wrapper.js     │   │   │ │
│  │  │  │             │  │ - claude-native stub       │   │   │ │
│  │  │  └──────┬──────┘  └────────────────────────────┘   │   │ │
│  │  │         │                                           │   │ │
│  │  │         ▼                                           │   │ │
│  │  │  ┌──────────────┐                                   │   │ │
│  │  │  │ Zypak        │  (Chromium sandbox wrapper)       │   │ │
│  │  │  └──────┬───────┘                                   │   │ │
│  │  └─────────┼───────────────────────────────────────────┘   │ │
│  │            │                                                │ │
│  │  ┌─────────▼───────────────────────────────────────────┐   │ │
│  │  │           Freedesktop Runtime (25.08)                │   │ │
│  │  │  ┌──────────────────────────────────────────────┐   │   │ │
│  │  │  │ + Electron2.BaseApp (Zypak, libsecret, etc)  │   │   │ │
│  │  │  └──────────────────────────────────────────────┘   │   │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                                             │ │
│  │  Permissions (via finish-args):                             │ │
│  │  ├─ --share=ipc                (X11 shared memory)         │ │
│  │  ├─ --socket=x11               (X11 display)               │ │
│  │  ├─ --socket=wayland           (Wayland display)           │ │
│  │  ├─ --socket=pulseaudio        (Audio)                     │ │
│  │  ├─ --share=network            (Network access)            │ │
│  │  ├─ --device=dri               (GPU acceleration)          │ │
│  │  ├─ --filesystem=~/.config/Claude:create                   │ │
│  │  └─ --talk-name=org.freedesktop.Notifications              │ │
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
│  Host Access via Portals:                                        │
│  ├─ File chooser (xdg-desktop-portal)                           │
│  ├─ Notifications                                                │
│  └─ URI handlers (claude://)                                     │
└──────────────────────────────────────────────────────────────────┘
```

### 3.2 Key Components

1. **Electron Binary**: Bundled within the Flatpak (not from runtime)
2. **Zypak Wrapper**: Enables Chromium sandbox within Flatpak sandbox
3. **app.asar**: Patched Claude application code
4. **Launch Script**: Handles environment setup and Wayland/X11 detection
5. **Desktop Integration**: .desktop file, icons, MIME handlers

### 3.3 Data Flow

```
User launches "Claude Desktop"
        │
        ▼
flatpak run io.github.aaddrick.claude-desktop
        │
        ▼
/app/bin/claude-desktop (launch script)
        │
        ├─► Detects display server (Wayland/X11)
        ├─► Sets environment variables
        ├─► Reads user flags from config
        │
        ▼
zypak-wrapper /app/lib/electron/electron /app/lib/resources/app.asar
        │
        ▼
Electron renders Claude Desktop UI
```

---

## 4. Implementation Phases

### Phase 1: Foundation (Week 1)
- [ ] Create Flatpak manifest file
- [ ] Create launch script
- [ ] Create AppStream metadata
- [ ] Test local build with flatpak-builder

### Phase 2: Integration (Week 2)
- [ ] Add `--build flatpak` to `build.sh`
- [ ] Create `scripts/build-flatpak.sh`
- [ ] Integrate existing app.asar patching logic
- [ ] Test both amd64 and arm64 builds

### Phase 3: CI/CD (Week 3)
- [ ] Create `build-flatpak.yml` GitHub workflow
- [ ] Add Flatpak to CI matrix
- [ ] Configure artifact uploads
- [ ] Test automated builds

### Phase 4: Flathub Submission (Week 4)
- [ ] Create Flathub submission repository
- [ ] Configure external data checker
- [ ] Submit PR to Flathub
- [ ] Address review feedback

### Phase 5: Maintenance (Ongoing)
- [ ] Automated version updates
- [ ] Runtime version updates
- [ ] Bug fixes and improvements

---

## 5. File Structure

### 5.1 New Files to Create

```
claude-desktop-debian/
├── flatpak/
│   ├── io.github.aaddrick.claude-desktop.yml    # Main manifest
│   ├── io.github.aaddrick.claude-desktop.metainfo.xml  # AppStream
│   ├── claude-desktop.sh                         # Launch script
│   ├── flathub.json                             # Flathub config
│   └── patches/                                  # Any needed patches
│       └── (empty initially)
├── scripts/
│   └── build-flatpak.sh                         # Build script (new)
└── .github/
    └── workflows/
        └── build-flatpak.yml                    # CI workflow (new)
```

### 5.2 Application ID

**Recommended ID:** `io.github.aaddrick.claude-desktop`

**Rationale:**
- Follows reverse-DNS convention
- Uses `io.github.` prefix for GitHub-hosted projects
- Matches existing AppImage component ID convention
- Unique and unlikely to conflict

---

## 6. Flatpak Manifest Design

### 6.1 Complete Manifest (io.github.aaddrick.claude-desktop.yml)

```yaml
# Flatpak manifest for Claude Desktop
# Application ID: io.github.aaddrick.claude-desktop
# Maintainer: Claude Desktop Linux Maintainers

app-id: io.github.aaddrick.claude-desktop
runtime: org.freedesktop.Platform
runtime-version: '25.08'
sdk: org.freedesktop.Sdk
base: org.electronjs.Electron2.BaseApp
base-version: '25.08'
command: claude-desktop

# Disable separate locale extension (not needed for Electron)
separate-locales: false

# Sandbox permissions
finish-args:
  # Display access
  - --share=ipc
  - --socket=x11
  - --socket=wayland
  - --socket=fallback-x11

  # Audio access
  - --socket=pulseaudio

  # Network access (required for Claude API)
  - --share=network

  # GPU acceleration
  - --device=dri

  # Application data directory
  - --filesystem=~/.config/Claude:create

  # MCP configuration
  - --filesystem=~/.config/Claude/claude_desktop_config.json:create

  # Log directory
  - --filesystem=xdg-cache/claude-desktop-debian:create

  # Desktop notifications
  - --talk-name=org.freedesktop.Notifications

  # System tray support (AppIndicator/StatusNotifierItem)
  - --talk-name=org.kde.StatusNotifierWatcher
  - --talk-name=com.canonical.AppMenu.Registrar
  - --talk-name=com.canonical.indicator.application

  # Screen saver inhibition (prevent sleep during long conversations)
  - --talk-name=org.freedesktop.ScreenSaver
  - --talk-name=org.gnome.SessionManager

  # Global shortcuts portal (for Ctrl+Alt+Space hotkey)
  - --talk-name=org.freedesktop.portal.GlobalShortcuts

  # Secret storage (for authentication)
  - --talk-name=org.freedesktop.secrets
  - --talk-name=org.gnome.keyring

  # URI handler registration (claude://)
  - --own-name=io.github.aaddrick.claude-desktop

# Modules to build
modules:
  # Module 1: libappindicator (for system tray)
  - shared-modules/libappindicator/libappindicator-gtk3-12.10.json

  # Module 2: dbus-glib (dependency for libappindicator)
  - shared-modules/dbus-glib/dbus-glib.json

  # Module 3: Claude Desktop
  - name: claude-desktop
    buildsystem: simple
    build-options:
      env:
        # Ensure we use the right architecture
        FLATPAK_ARCH: "${FLATPAK_ARCH}"
    build-commands:
      # Create directory structure
      - mkdir -p /app/lib/electron
      - mkdir -p /app/lib/resources
      - mkdir -p /app/bin
      - mkdir -p /app/share/applications
      - mkdir -p /app/share/icons/hicolor/256x256/apps
      - mkdir -p /app/share/icons/hicolor/128x128/apps
      - mkdir -p /app/share/icons/hicolor/64x64/apps
      - mkdir -p /app/share/icons/hicolor/48x48/apps
      - mkdir -p /app/share/icons/hicolor/32x32/apps
      - mkdir -p /app/share/icons/hicolor/16x16/apps
      - mkdir -p /app/share/metainfo

      # Copy Electron distribution
      - cp -r electron-dist/* /app/lib/electron/
      - chmod +x /app/lib/electron/electron

      # Copy patched app.asar and unpacked modules
      - cp app.asar /app/lib/resources/
      - cp -r app.asar.unpacked /app/lib/resources/

      # Copy icons
      - install -Dm644 icons/256x256.png /app/share/icons/hicolor/256x256/apps/io.github.aaddrick.claude-desktop.png
      - install -Dm644 icons/128x128.png /app/share/icons/hicolor/128x128/apps/io.github.aaddrick.claude-desktop.png
      - install -Dm644 icons/64x64.png /app/share/icons/hicolor/64x64/apps/io.github.aaddrick.claude-desktop.png
      - install -Dm644 icons/48x48.png /app/share/icons/hicolor/48x48/apps/io.github.aaddrick.claude-desktop.png
      - install -Dm644 icons/32x32.png /app/share/icons/hicolor/32x32/apps/io.github.aaddrick.claude-desktop.png
      - install -Dm644 icons/16x16.png /app/share/icons/hicolor/16x16/apps/io.github.aaddrick.claude-desktop.png

      # Install launcher script
      - install -Dm755 claude-desktop.sh /app/bin/claude-desktop

      # Install desktop file
      - install -Dm644 io.github.aaddrick.claude-desktop.desktop /app/share/applications/io.github.aaddrick.claude-desktop.desktop

      # Install AppStream metainfo
      - install -Dm644 io.github.aaddrick.claude-desktop.metainfo.xml /app/share/metainfo/io.github.aaddrick.claude-desktop.metainfo.xml

    sources:
      # Electron distribution (downloaded during build)
      - type: archive
        only-arches:
          - x86_64
        url: https://github.com/nickvnv/nickvnv-org.nickvnv.anthropic-claude/releases/download/v0.0.0/electron-v33.2.1-linux-x64.tar.gz
        sha256: PLACEHOLDER_AMD64_SHA256
        dest: electron-dist
        # Note: Replace with actual Electron download URL and sha256
        # x-checker-data will be configured for auto-updates

      - type: archive
        only-arches:
          - aarch64
        url: https://github.com/nickvnv/nickvnv-org.nickvnv.anthropic-claude/releases/download/v0.0.0/electron-v33.2.1-linux-arm64.tar.gz
        sha256: PLACEHOLDER_ARM64_SHA256
        dest: electron-dist

      # Patched app.asar (generated by build script)
      - type: file
        path: app.asar

      # Unpacked native modules
      - type: dir
        path: app.asar.unpacked

      # Icons (generated from Windows executable)
      - type: dir
        path: icons

      # Launch script
      - type: file
        path: claude-desktop.sh

      # Desktop file
      - type: file
        path: io.github.aaddrick.claude-desktop.desktop

      # AppStream metainfo
      - type: file
        path: io.github.aaddrick.claude-desktop.metainfo.xml

# Cleanup unnecessary files
cleanup:
  - /include
  - /lib/pkgconfig
  - /share/man
  - '*.la'
  - '*.a'
```

### 6.2 Desktop Entry File

```ini
# io.github.aaddrick.claude-desktop.desktop

[Desktop Entry]
Name=Claude Desktop
GenericName=AI Assistant
Comment=Claude AI Desktop Application for Linux
Exec=claude-desktop %u
Icon=io.github.aaddrick.claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
Keywords=AI;Assistant;Claude;Anthropic;Chat;
X-Flatpak-RenamedFrom=claude-desktop.desktop;
```

### 6.3 Launch Script (claude-desktop.sh)

```bash
#!/bin/bash
# Launch script for Claude Desktop Flatpak
# Handles Wayland/X11 detection and Electron configuration

set -e

# Logging setup
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-debian"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/launcher.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "=== Claude Desktop Flatpak Launch ==="
log "Arguments: $*"

# Read user-defined flags
FLAGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude-flags.conf"
EXTRA_FLAGS=()
if [ -f "$FLAGS_FILE" ]; then
    log "Reading flags from $FLAGS_FILE"
    while IFS= read -r line; do
        # Skip empty lines and comments
        if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
            EXTRA_FLAGS+=("$line")
            log "Added flag: $line"
        fi
    done < "$FLAGS_FILE"
fi

# Electron environment
export ELECTRON_FORCE_IS_PACKAGED=true
export ELECTRON_USE_SYSTEM_TITLE_BAR=1

# Base arguments
ELECTRON_ARGS=(
    "/app/lib/resources/app.asar"
    "--disable-features=CustomTitlebar"
)

# Detect display server and configure accordingly
if [ -n "$WAYLAND_DISPLAY" ]; then
    log "Wayland display detected: $WAYLAND_DISPLAY"
    ELECTRON_ARGS+=(
        "--enable-features=UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal"
        "--ozone-platform=wayland"
        "--enable-wayland-ime"
        "--wayland-text-input-version=3"
    )
    # Enable speech dispatcher for accessibility
    ELECTRON_ARGS+=("--enable-speech-dispatcher")
elif [ -n "$DISPLAY" ]; then
    log "X11 display detected: $DISPLAY"
    ELECTRON_ARGS+=("--enable-speech-dispatcher")
else
    log "ERROR: No display server detected"
    echo "Error: Claude Desktop requires a graphical desktop environment." >&2
    exit 1
fi

# Add user-defined flags
ELECTRON_ARGS+=("${EXTRA_FLAGS[@]}")

# Add any command-line arguments passed to the script
ELECTRON_ARGS+=("$@")

log "Launching with args: ${ELECTRON_ARGS[*]}"

# Launch via zypak-wrapper (provided by Electron BaseApp)
# zypak enables Chromium's sandbox within Flatpak's sandbox
cd /app/lib/electron
exec zypak-wrapper ./electron "${ELECTRON_ARGS[@]}" >> "$LOG_FILE" 2>&1
```

### 6.4 AppStream Metadata

```xml
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>io.github.aaddrick.claude-desktop</id>

  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT AND Apache-2.0</project_license>

  <name>Claude Desktop</name>
  <summary>AI assistant from Anthropic</summary>

  <developer id="io.github.aaddrick">
    <name>Claude Desktop Linux Maintainers</name>
  </developer>

  <description>
    <p>
      Claude Desktop provides a native desktop experience for interacting with
      Claude, Anthropic's AI assistant. This is an unofficial Linux port that
      repackages the official Windows application.
    </p>
    <p>Features:</p>
    <ul>
      <li>Native Linux support without virtualization or Wine</li>
      <li>Full Model Context Protocol (MCP) integration</li>
      <li>System tray integration</li>
      <li>Global hotkey support (Ctrl+Alt+Space on X11)</li>
      <li>Both X11 and Wayland support</li>
    </ul>
    <p>
      Note: This is an unofficial build. For official support, please visit
      Anthropic's website.
    </p>
  </description>

  <launchable type="desktop-id">io.github.aaddrick.claude-desktop.desktop</launchable>

  <icon type="stock">io.github.aaddrick.claude-desktop</icon>

  <url type="homepage">https://github.com/aaddrick/claude-desktop-debian</url>
  <url type="bugtracker">https://github.com/aaddrick/claude-desktop-debian/issues</url>
  <url type="vcs-browser">https://github.com/aaddrick/claude-desktop-debian</url>

  <screenshots>
    <screenshot type="default">
      <image>https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45</image>
      <caption>Claude Desktop main window</caption>
    </screenshot>
    <screenshot>
      <image>https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1</image>
      <caption>Global hotkey popup</caption>
    </screenshot>
    <screenshot>
      <image>https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559</image>
      <caption>System tray menu</caption>
    </screenshot>
  </screenshots>

  <categories>
    <category>Office</category>
    <category>Utility</category>
    <category>Network</category>
  </categories>

  <keywords>
    <keyword>AI</keyword>
    <keyword>Assistant</keyword>
    <keyword>Claude</keyword>
    <keyword>Anthropic</keyword>
    <keyword>Chat</keyword>
    <keyword>LLM</keyword>
  </keywords>

  <provides>
    <binary>claude-desktop</binary>
  </provides>

  <requires>
    <display_length compare="ge">768</display_length>
    <internet>always</internet>
  </requires>

  <supports>
    <control>pointing</control>
    <control>keyboard</control>
  </supports>

  <content_rating type="oars-1.1">
    <content_attribute id="social-chat">intense</content_attribute>
    <content_attribute id="social-info">moderate</content_attribute>
  </content_rating>

  <releases>
    <release version="PLACEHOLDER_VERSION" date="PLACEHOLDER_DATE">
      <description>
        <p>Initial Flatpak release.</p>
      </description>
    </release>
  </releases>

</component>
```

### 6.5 Flathub Configuration (flathub.json)

```json
{
  "skip-appstream-check": false,
  "only-arches": ["x86_64", "aarch64"],
  "end-of-life": null,
  "end-of-life-rebase": null
}
```

---

## 7. Build Script Modifications

### 7.1 Modify build.sh

Add `flatpak` to the BUILD_FORMAT options:

```bash
# In argument parsing section, modify:
BUILD_FORMAT="deb"    # Default

# Add to validation:
if [[ "$BUILD_FORMAT" != "deb" && "$BUILD_FORMAT" != "appimage" && "$BUILD_FORMAT" != "flatpak" ]]; then
    echo "Invalid build format: '$BUILD_FORMAT'. Must be 'deb', 'appimage', or 'flatpak'." >&2
    exit 1
fi

# Add to help text:
echo "  --build: Specify the build format (deb, appimage, or flatpak). Default: deb"

# Add build call section:
elif [ "$BUILD_FORMAT" = "flatpak" ]; then
    echo "Calling Flatpak packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-flatpak.sh
    if ! scripts/build-flatpak.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"; then
        echo "Flatpak packaging script failed."
        exit 1
    fi
    echo "Flatpak Build complete!"
fi
```

### 7.2 Create scripts/build-flatpak.sh

```bash
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
FLATPAK_BUILD_DIR="$WORK_DIR/flatpak-build"
FLATPAK_STAGING="$WORK_DIR/flatpak-staging"
FLATPAK_REPO="$WORK_DIR/flatpak-repo"

# Map architecture
case "$ARCHITECTURE" in
    "amd64") FLATPAK_ARCH="x86_64" ;;
    "arm64") FLATPAK_ARCH="aarch64" ;;
    *) echo "Unsupported architecture: $ARCHITECTURE"; exit 1 ;;
esac

# Clean previous builds
rm -rf "$FLATPAK_BUILD_DIR" "$FLATPAK_STAGING" "$FLATPAK_REPO"
mkdir -p "$FLATPAK_STAGING"

# --- Prepare staging area ---
echo "Preparing Flatpak staging area..."

# Copy app.asar
cp "$APP_STAGING_DIR/app.asar" "$FLATPAK_STAGING/"
cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$FLATPAK_STAGING/"

# Copy Electron distribution
if [ -d "$APP_STAGING_DIR/node_modules/electron/dist" ]; then
    cp -r "$APP_STAGING_DIR/node_modules/electron/dist" "$FLATPAK_STAGING/electron-dist"
else
    echo "Electron distribution not found in staging area"
    exit 1
fi

# --- Prepare icons ---
echo "Preparing icons..."
ICONS_DIR="$FLATPAK_STAGING/icons"
mkdir -p "$ICONS_DIR"

# Map icon files
declare -A icon_sizes=(
    ["256x256"]="claude_6_256x256x32.png"
    ["128x128"]="claude_7_64x64x32.png"  # Scale up 64 to 128
    ["64x64"]="claude_7_64x64x32.png"
    ["48x48"]="claude_8_48x48x32.png"
    ["32x32"]="claude_10_32x32x32.png"
    ["16x16"]="claude_13_16x16x32.png"
)

for size in "${!icon_sizes[@]}"; do
    src_file="$WORK_DIR/${icon_sizes[$size]}"
    if [ -f "$src_file" ]; then
        # Use imagemagick to resize if needed
        if command -v convert &> /dev/null; then
            convert "$src_file" -resize "$size" "$ICONS_DIR/${size}.png"
        else
            cp "$src_file" "$ICONS_DIR/${size}.png"
        fi
    fi
done

# --- Copy Flatpak files ---
echo "Copying Flatpak configuration files..."
FLATPAK_SRC="$(dirname "$(dirname "$(realpath "$0")")")/flatpak"

cp "$FLATPAK_SRC/claude-desktop.sh" "$FLATPAK_STAGING/"
cp "$FLATPAK_SRC/$FLATPAK_ID.desktop" "$FLATPAK_STAGING/"
cp "$FLATPAK_SRC/$FLATPAK_ID.metainfo.xml" "$FLATPAK_STAGING/"

# Update version in metainfo
sed -i "s/PLACEHOLDER_VERSION/$VERSION/g" "$FLATPAK_STAGING/$FLATPAK_ID.metainfo.xml"
sed -i "s/PLACEHOLDER_DATE/$(date +%Y-%m-%d)/g" "$FLATPAK_STAGING/$FLATPAK_ID.metainfo.xml"

# --- Generate manifest with correct source paths ---
echo "Generating Flatpak manifest..."
MANIFEST_FILE="$FLATPAK_STAGING/$FLATPAK_ID.yml"

cat > "$MANIFEST_FILE" << MANIFEST_EOF
app-id: $FLATPAK_ID
runtime: org.freedesktop.Platform
runtime-version: '25.08'
sdk: org.freedesktop.Sdk
base: org.electronjs.Electron2.BaseApp
base-version: '25.08'
command: claude-desktop
separate-locales: false

finish-args:
  - --share=ipc
  - --socket=x11
  - --socket=wayland
  - --socket=fallback-x11
  - --socket=pulseaudio
  - --share=network
  - --device=dri
  - --filesystem=~/.config/Claude:create
  - --filesystem=xdg-cache/claude-desktop-debian:create
  - --talk-name=org.freedesktop.Notifications
  - --talk-name=org.kde.StatusNotifierWatcher
  - --talk-name=com.canonical.AppMenu.Registrar
  - --talk-name=org.freedesktop.ScreenSaver
  - --talk-name=org.freedesktop.portal.GlobalShortcuts
  - --talk-name=org.freedesktop.secrets
  - --own-name=$FLATPAK_ID

modules:
  - shared-modules/libappindicator/libappindicator-gtk3-12.10.json
  - shared-modules/dbus-glib/dbus-glib.json

  - name: claude-desktop
    buildsystem: simple
    build-commands:
      - mkdir -p /app/lib/electron /app/lib/resources /app/bin
      - mkdir -p /app/share/applications /app/share/metainfo
      - mkdir -p /app/share/icons/hicolor/256x256/apps
      - mkdir -p /app/share/icons/hicolor/128x128/apps
      - mkdir -p /app/share/icons/hicolor/64x64/apps
      - mkdir -p /app/share/icons/hicolor/48x48/apps
      - mkdir -p /app/share/icons/hicolor/32x32/apps
      - mkdir -p /app/share/icons/hicolor/16x16/apps

      - cp -r electron-dist/* /app/lib/electron/
      - chmod +x /app/lib/electron/electron

      - cp app.asar /app/lib/resources/
      - cp -r app.asar.unpacked /app/lib/resources/

      - install -Dm644 icons/256x256.png /app/share/icons/hicolor/256x256/apps/$FLATPAK_ID.png
      - install -Dm644 icons/64x64.png /app/share/icons/hicolor/64x64/apps/$FLATPAK_ID.png
      - install -Dm644 icons/48x48.png /app/share/icons/hicolor/48x48/apps/$FLATPAK_ID.png
      - install -Dm644 icons/32x32.png /app/share/icons/hicolor/32x32/apps/$FLATPAK_ID.png
      - install -Dm644 icons/16x16.png /app/share/icons/hicolor/16x16/apps/$FLATPAK_ID.png

      - install -Dm755 claude-desktop.sh /app/bin/claude-desktop
      - install -Dm644 $FLATPAK_ID.desktop /app/share/applications/$FLATPAK_ID.desktop
      - install -Dm644 $FLATPAK_ID.metainfo.xml /app/share/metainfo/$FLATPAK_ID.metainfo.xml

    sources:
      - type: dir
        path: electron-dist
        dest: electron-dist
      - type: file
        path: app.asar
      - type: dir
        path: app.asar.unpacked
      - type: dir
        path: icons
      - type: file
        path: claude-desktop.sh
      - type: file
        path: $FLATPAK_ID.desktop
      - type: file
        path: $FLATPAK_ID.metainfo.xml

cleanup:
  - /include
  - /lib/pkgconfig
  - /share/man
  - '*.la'
  - '*.a'
MANIFEST_EOF

# --- Install shared-modules ---
echo "Setting up shared-modules..."
cd "$FLATPAK_STAGING"
if [ ! -d "shared-modules" ]; then
    git clone --depth=1 https://github.com/flathub/shared-modules.git
fi

# --- Build Flatpak ---
echo "Building Flatpak..."

# Install runtime and SDK if not present
flatpak install --user -y flathub org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08 || true
flatpak install --user -y flathub org.electronjs.Electron2.BaseApp//25.08 || true

# Build with flatpak-builder
flatpak-builder \
    --arch="$FLATPAK_ARCH" \
    --force-clean \
    --repo="$FLATPAK_REPO" \
    "$FLATPAK_BUILD_DIR" \
    "$MANIFEST_FILE"

# --- Create bundle ---
echo "Creating Flatpak bundle..."
BUNDLE_FILE="$WORK_DIR/${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.flatpak"

flatpak build-bundle \
    --arch="$FLATPAK_ARCH" \
    "$FLATPAK_REPO" \
    "$BUNDLE_FILE" \
    "$FLATPAK_ID"

echo "Flatpak bundle created: $BUNDLE_FILE"

# --- Verify bundle ---
echo "Verifying Flatpak bundle..."
flatpak info --arch="$FLATPAK_ARCH" "$BUNDLE_FILE" || echo "Bundle verification skipped (not installed)"

echo "--- Flatpak Package Build Finished ---"
echo "Output: $BUNDLE_FILE"

exit 0
```

---

## 8. GitHub Workflow Integration

### 8.1 Create .github/workflows/build-flatpak.yml

```yaml
name: Build Flatpak Package (Reusable)

on:
  workflow_call:
    inputs:
      architecture:
        description: 'Target architecture (amd64 or arm64)'
        required: true
        type: string
      build_flags:
        description: 'Additional flags for build.sh'
        required: false
        type: string
        default: ""

jobs:
  build:
    runs-on: ${{ inputs.architecture == 'arm64' && 'ubuntu-22.04-arm' || 'ubuntu-latest' }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Flatpak and dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y flatpak flatpak-builder git

      - name: Add Flathub repository
        run: |
          flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

      - name: Install Flatpak runtimes
        run: |
          flatpak install --user -y flathub org.freedesktop.Platform//25.08
          flatpak install --user -y flathub org.freedesktop.Sdk//25.08
          flatpak install --user -y flathub org.electronjs.Electron2.BaseApp//25.08

      - name: Make build script executable
        run: chmod +x ./build.sh

      - name: Run Flatpak build
        run: |
          ./build.sh --build flatpak ${{ inputs.build_flags }}

      - name: Upload Flatpak artifact
        uses: actions/upload-artifact@v4
        with:
          name: package-${{ inputs.architecture }}-flatpak
          path: |
            claude-desktop-*.flatpak
          if-no-files-found: error
```

### 8.2 Update .github/workflows/ci.yml

Add Flatpak builds to the CI matrix:

```yaml
  build-flatpak-amd64:
    name: Build Flatpak (amd64)
    needs: test-flags
    uses: ./.github/workflows/build-flatpak.yml
    with:
      architecture: amd64

  build-flatpak-arm64:
    name: Build Flatpak (arm64)
    needs: test-flags
    uses: ./.github/workflows/build-flatpak.yml
    with:
      architecture: arm64
```

---

## 9. Flathub Submission Process

### 9.1 Prerequisites

1. GitHub account
2. Flatpak successfully builds locally
3. AppStream metadata passes validation
4. Application works correctly

### 9.2 Submission Steps

1. **Fork flathub/flathub repository**

2. **Create new branch with app ID**
   ```bash
   git checkout -b new-pr
   mkdir io.github.aaddrick.claude-desktop
   ```

3. **Add manifest files**
   ```
   io.github.aaddrick.claude-desktop/
   ├── io.github.aaddrick.claude-desktop.yml
   ├── io.github.aaddrick.claude-desktop.metainfo.xml
   ├── io.github.aaddrick.claude-desktop.desktop
   ├── claude-desktop.sh
   └── flathub.json
   ```

4. **Configure external data checker** (for auto-updates)
   ```yaml
   # In manifest, add x-checker-data to sources
   - type: archive
     url: https://github.com/electron/electron/releases/download/...
     sha256: ...
     x-checker-data:
       type: json
       url: https://api.github.com/repos/aaddrick/claude-desktop-debian/releases/latest
       version-query: .tag_name | sub("^v"; "")
       url-query: .assets[] | select(.name | test("linux-x64")) | .browser_download_url
   ```

5. **Submit Pull Request**
   - Title: `Add io.github.aaddrick.claude-desktop`
   - Description: Include app description, screenshots, and build instructions

6. **Address Review Feedback**
   - Typical feedback: permissions, metadata quality, build reproducibility

### 9.3 Flathub Requirements Checklist

- [ ] Valid AppStream metadata (appstream-util validate)
- [ ] Desktop file passes validation (desktop-file-validate)
- [ ] Icon in correct size (at least 128x128)
- [ ] No network access during build
- [ ] Reproducible builds
- [ ] Minimal sandbox permissions
- [ ] No bundled libraries available in runtime

---

## 10. Testing Strategy

### 10.1 Local Testing

```bash
# Build locally
./build.sh --build flatpak

# Install from bundle
flatpak install --user ./claude-desktop-VERSION-ARCH.flatpak

# Run
flatpak run io.github.aaddrick.claude-desktop

# Check logs
cat ~/.var/app/io.github.aaddrick.claude-desktop/cache/claude-desktop-debian/launcher.log

# Test permissions
flatpak info --show-permissions io.github.aaddrick.claude-desktop
```

### 10.2 Test Scenarios

| Test | X11 | Wayland | Expected |
|------|-----|---------|----------|
| Launch | Pass | Pass | Window opens |
| Login | Pass | Pass | claude:// URI handled |
| System tray | Pass | Pass | Tray icon visible |
| Notifications | Pass | Pass | Notifications show |
| Global hotkey | Pass | Limited | Ctrl+Alt+Space works (portal) |
| MCP | Pass | Pass | Config loaded from ~/.config/Claude |
| GPU acceleration | Pass | Pass | Smooth scrolling |

### 10.3 Automated Tests

```bash
# Validate AppStream
flatpak run org.freedesktop.appstream-glib validate \
  /app/share/metainfo/io.github.aaddrick.claude-desktop.metainfo.xml

# Validate desktop file
desktop-file-validate io.github.aaddrick.claude-desktop.desktop

# Check permissions
flatpak info --show-permissions io.github.aaddrick.claude-desktop

# Lint manifest
flatpak-builder --show-deps io.github.aaddrick.claude-desktop.yml
```

---

## 11. Known Challenges and Solutions

### 11.1 Challenge: Chromium Sandbox in Flatpak

**Problem**: Chromium's sandbox conflicts with Flatpak's sandbox.

**Solution**: Use Zypak wrapper (provided by Electron2.BaseApp) which intercepts sandbox calls and redirects them through Flatpak's security model.

### 11.2 Challenge: Global Hotkeys on Wayland

**Problem**: Wayland doesn't allow apps to capture global hotkeys.

**Solution**: Use GlobalShortcuts portal (org.freedesktop.portal.GlobalShortcuts). Enable via `--enable-features=GlobalShortcutsPortal` flag. Note: Requires user to grant permission.

### 11.3 Challenge: URI Handler Registration

**Problem**: claude:// URLs need to open Claude Desktop.

**Solution**:
- Desktop file includes `MimeType=x-scheme-handler/claude;`
- Flatpak automatically registers MIME handlers
- User may need to set default handler: `xdg-mime default io.github.aaddrick.claude-desktop.desktop x-scheme-handler/claude`

### 11.4 Challenge: System Tray on Various DEs

**Problem**: System tray implementation varies by desktop environment.

**Solution**: Use libappindicator (from shared-modules) which supports:
- KDE StatusNotifierItem
- GNOME (via AppIndicator extension)
- XFCE, MATE, Cinnamon

### 11.5 Challenge: Native Module Stubs

**Problem**: claude-native module has Windows-specific code.

**Solution**: Already handled by existing stub implementation in build.sh. The stub provides no-op implementations for Windows-specific functions.

### 11.6 Challenge: Config Directory Access

**Problem**: MCP config at `~/.config/Claude/claude_desktop_config.json`.

**Solution**: Grant filesystem access via:
```yaml
finish-args:
  - --filesystem=~/.config/Claude:create
```

### 11.7 Challenge: Electron Version Compatibility

**Problem**: Electron version must match BaseApp expectations.

**Solution**:
- Use same Electron major version as BaseApp
- Current BaseApp 25.08 supports Electron 33.x
- Pin Electron version in manifest

---

## 12. Appendix: Reference Implementations

### 12.1 Discord Flatpak

**Repository**: https://github.com/flathub/com.discordapp.Discord

**Key Patterns**:
- Uses Electron2.BaseApp
- Launch script handles IPC sockets
- User flags via config file
- socat for IPC bridging

### 12.2 Slack Flatpak

**Repository**: https://github.com/flathub/com.slack.Slack

**Key Patterns**:
- Extracts from Snap package
- libsecret for credential storage
- lsb_release for system info
- Wayland opt-in

### 12.3 Spotify Flatpak

**Repository**: https://github.com/flathub/com.spotify.Client

**Key Patterns**:
- FFmpeg bundled for codec support
- preload library for compatibility
- User-defined flags file
- MPRIS integration

### 12.4 Useful Links

- [Flatpak Documentation](https://docs.flatpak.org/)
- [Electron Flatpak Guide](https://docs.flatpak.org/en/latest/electron.html)
- [Flathub Submission Guide](https://github.com/flathub/flathub/wiki/App-Submission)
- [Zypak Documentation](https://github.com/nickvnv/nickvnv-org.nickvnv.anthropic-claude/refi64/zypak)
- [shared-modules Repository](https://github.com/flathub/shared-modules)
- [AppStream Specification](https://www.freedesktop.org/software/appstream/docs/)

---

## Summary

This plan provides a comprehensive roadmap for implementing Claude Desktop as a Flatpak package. The implementation leverages:

1. **Freedesktop Runtime** (25.08) - Minimal, well-supported base
2. **Electron2.BaseApp** - Provides Zypak, libsecret, and other Electron necessities
3. **Existing build infrastructure** - Reuses app.asar patching from current build.sh
4. **Flathub distribution** - Standard, trusted Linux app distribution

The estimated effort is 3-4 weeks for initial implementation, with ongoing maintenance for version updates and bug fixes.

---

*Document Version: 1.0*
*Created: $(date +%Y-%m-%d)*
*Author: Claude Desktop Linux Maintainers*
