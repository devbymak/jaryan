#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p 'Jarian.app/Contents/MacOS' 'Jarian.app/Contents/Resources' .build/app-icon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/app-icon.png --out ".build/app-icon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/app-icon.png --out ".build/app-icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p .build/module-cache
jarian_cache_path="$(cd .build/module-cache && pwd -P)"
xcrun swift -module-cache-path "$jarian_cache_path" sources/icon.swift .build/app-icon.iconset 'Jarian.app/Contents/Resources/app-icon.icns'
xcrun swiftc -target arm64-apple-macosx13.0 -module-cache-path "$jarian_cache_path" -swift-version 5 -O -framework AppKit -framework SystemConfiguration -framework ServiceManagement -framework Network sources/traffic.swift sources/graph.swift sources/main.swift -o 'Jarian.app/Contents/MacOS/jarian'
cat > 'Jarian.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>jarian</string>
<key>CFBundleIdentifier</key><string>local.jarian</string>
<key>CFBundleName</key><string>Jarian</string>
<key>CFBundleDisplayName</key><string>Jarian</string>
<key>CFBundleIconFile</key><string>app-icon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# App Sandbox with outgoing connections only: no file access outside its own container, no incoming connections.
cat > .build/jarian.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
# On the first sandboxed launch, macOS moves preferences saved by earlier, unsandboxed builds into the container.
cat > 'Jarian.app/Contents/Resources/container-migration.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Move</key><array><string>${Library}/Preferences/local.jarian.plist</string></array>
</dict></plist>
PLIST
# Ad-hoc by default, which runs only on this Mac. To share the app, set JARIAN_SIGN_IDENTITY to a Developer ID
# Application identity, then notarize it (see readme.md); a secure timestamp is required for notarization.
identity="${JARIAN_SIGN_IDENTITY:--}"
timestamp=()
[[ "$identity" == - ]] || timestamp=(--timestamp)
codesign --force --sign "$identity" "${timestamp[@]}" --options runtime --entitlements .build/jarian.entitlements 'Jarian.app'
echo 'Built Jarian.app'
if [[ "${1:-}" == "--install" ]]; then
  # Replace only an earlier Jarian, never another app with the same name.
  if [[ -e '/Applications/Jarian.app' && "$(plutil -extract CFBundleIdentifier raw -o - '/Applications/Jarian.app/Contents/Info.plist' 2>/dev/null || true)" != local.jarian ]]; then
    echo '/Applications/Jarian.app is not Jarian; leaving it in place.' >&2; exit 1
  fi
  # Quit every running copy first, wherever it was started; it saves today's usage before exiting. Matched by bundle ID,
  # like the app's own one-copy check, so a copy still running would also make the new one quit at launch.
  running() { [[ -n "$(lsappinfo find bundleid=local.jarian)" ]] }
  # A refused quit request (such as a declined Automation prompt) is caught by the check below.
  if running; then osascript -e 'tell application id "local.jarian" to quit' >/dev/null 2>&1 || true; fi
  for _ in {1..50}; do running || break; sleep 0.2; done
  if running; then echo 'Jarian is still running; quit it, then run ./build.sh --install again.' >&2; exit 1; fi
  rm -rf '/Applications/Jarian.app'
  ditto 'Jarian.app' '/Applications/Jarian.app'
  # Only the installed copy should handle Launch at Login.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/Jarian.app" 2>/dev/null || true  # Fails when it was never registered.
  open '/Applications/Jarian.app'
  echo 'Installed and opened /Applications/Jarian.app'
fi
