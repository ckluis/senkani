#!/bin/bash
# Wrap the swift-built SenkaniApp executable in a minimal .app bundle so
# macOS LaunchServices treats it as a GUI app and opens its main window.
# Then `open` it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/08-bundle.log"
SENKANI_REPO="/Users/clank/Desktop/projects/senkani"
APP_BIN="$SENKANI_REPO/.build/debug/SenkaniApp"
APP_DIR="$HERE/SenkaniApp.app"

{
  echo "=== Bundle build at $(date) ==="
  # Always rebuild — SwiftPM is incremental and decides correctly whether
  # work is needed. A gate on $APP_BIN's existence silently re-bundles
  # the stale binary during iterative source-edit cycles, which costs
  # the operator far more debug time than the rebuild costs them.
  echo "Building debug (incremental)"
  cd "$SENKANI_REPO"
  /usr/bin/swift build --product SenkaniApp 2>&1 | tail -20
  if [ ! -x "$APP_BIN" ]; then
    echo "ERROR: build did not produce $APP_BIN — aborting bundle"
    exit 1
  fi

  # Surface which binary actually got bundled, so the operator can
  # confirm at a glance that they bundled the post-edit version.
  if /usr/bin/stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$APP_BIN" >/dev/null 2>&1; then
    BIN_MTIME="$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$APP_BIN")"
  else
    BIN_MTIME="$(/usr/bin/stat -c '%y' "$APP_BIN" 2>/dev/null || echo unknown)"
  fi
  echo "Bundled binary built at $BIN_MTIME — $APP_BIN"

  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR/Contents/MacOS"
  mkdir -p "$APP_DIR/Contents/Resources"
  cp "$APP_BIN" "$APP_DIR/Contents/MacOS/SenkaniApp"
  cp "$SENKANI_REPO/SenkaniApp/Info.plist" "$APP_DIR/Contents/Info.plist"

  # Copy any resource bundles next to the binary that the app expects.
  cp -R "$SENKANI_REPO/.build/debug/"*.bundle "$APP_DIR/Contents/Resources/" 2>/dev/null || true
  cp -R "$SENKANI_REPO/.build/debug/"*.resources "$APP_DIR/Contents/Resources/" 2>/dev/null || true

  echo "Bundle: $APP_DIR"
  ls -la "$APP_DIR/Contents/" 2>&1
  echo "Bundle size: $(du -sh "$APP_DIR" | cut -f1)"

  # Register with LaunchServices then open.
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP_DIR" 2>&1 || true
  echo "Opening..."
  open "$APP_DIR"
  sleep 4
  echo "--- pgrep SenkaniApp ---"
  pgrep -fl SenkaniApp 2>&1 | head -10
} 2>&1 | tee "$LOG"
echo "DONE" > "$HERE/.phase-08-done"
echo "===== Phase 08 done. Terminal can close. ====="
