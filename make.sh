#!/bin/bash
# Build, package, and install LilTerminal.
#
#   ./make.sh              debug build   -> build/LilTerminal.app
#   ./make.sh --release    release build -> build/LilTerminal.app
#   ./make.sh --install    release build, installed to /Applications (replaces
#                          any previous version) and relaunched
#   ./make.sh --dmg        release build -> dist/LilTerminal-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.1"
APP="build/LilTerminal.app"
MODE="${1:-}"
CONFIG="debug"
[[ "$MODE" == "--release" || "$MODE" == "--install" || "$MODE" == "--dmg" ]] && CONFIG="release"

# --- icon -------------------------------------------------------------------
# Regenerated from source each time so the icon is never a stale binary blob.
mkdir -p build
if [[ ! -f build/LilTerminal.icns || Tools/makeicon.swift -nt build/LilTerminal.icns ]]; then
    swiftc -O -o build/makeicon Tools/makeicon.swift
    ./build/makeicon build/LilTerminal.iconset >/dev/null
    iconutil -c icns build/LilTerminal.iconset -o build/LilTerminal.icns
fi

# --- build ------------------------------------------------------------------
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LilTerminal"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LilTerminal"

# The session daemon ships beside the app binary. It owns the ptys, so shells
# survive the app quitting; the app launches it on demand.
DAEMON="$(swift build -c "$CONFIG" --show-bin-path)/lilterm-sessiond"
[ -f "$DAEMON" ] && cp "$DAEMON" "$APP/Contents/MacOS/lilterm-sessiond"
cp build/LilTerminal.icns "$APP/Contents/Resources/LilTerminal.icns"

# Ghostty's VT engine ships as a dylib (see Package.swift for why it is not
# linked statically). The binary looks for it on an @executable_path rpath.
mkdir -p "$APP/Contents/Frameworks"
cp Vendor/ghostty-vt/lib/libghostty-vt.dylib "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>LilTerminal</string>
    <key>CFBundleDisplayName</key>       <string>LilTerminal</string>
    <key>CFBundleIdentifier</key>        <string>app.lilterminal</string>
    <key>CFBundleExecutable</key>        <string>LilTerminal</string>
    <key>CFBundleIconFile</key>          <string>LilTerminal</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signing is enough for local use. The app is intentionally NOT
# sandboxed: reading other processes' CPU/memory via libproc is impossible
# inside the sandbox.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing skipped"
echo "Built $APP"

# --- install ----------------------------------------------------------------
if [[ "$MODE" == "--install" ]]; then
    DEST="/Applications/LilTerminal.app"
    # Quit the running copy first: replacing a bundle underneath a live process
    # leaves it running stale code and can corrupt its state on next launch.
    if pgrep -x LilTerminal >/dev/null; then
        osascript -e 'tell application "LilTerminal" to quit' 2>/dev/null || true
        for _ in $(seq 1 25); do pgrep -x LilTerminal >/dev/null || break; sleep 0.2; done
        pkill -x LilTerminal 2>/dev/null || true
        sleep 0.5
    fi
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    # Nudge Launch Services so the new icon and version are picked up.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$DEST" 2>/dev/null || true
    echo "Installed $DEST"
    open "$DEST"
fi

# --- dmg --------------------------------------------------------------------
if [[ "$MODE" == "--dmg" ]]; then
    mkdir -p dist
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    # The Applications symlink is what makes the drag-to-install window work.
    ln -s /Applications "$STAGE/Applications"
    DMG="dist/LilTerminal-$VERSION.dmg"
    rm -f "$DMG"
    hdiutil create -volname "LilTerminal" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "Packaged $DMG"
fi
