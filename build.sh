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
xcrun swiftc -target arm64-apple-macosx13.0 -module-cache-path "$jarian_cache_path" -swift-version 5 -O -framework AppKit -framework SystemConfiguration -framework ServiceManagement -framework Network sources/traffic.swift sources/main.swift -o 'Jarian.app/Contents/MacOS/jarian'
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
codesign --force --sign - --options runtime --entitlements .build/jarian.entitlements 'Jarian.app'
echo 'Built Jarian.app'
