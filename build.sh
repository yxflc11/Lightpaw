#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache dist
# Documents is File Provider managed; sign on local temporary storage before publishing.
STAGING="$(mktemp -d /private/tmp/codex-memorywatch-build.XXXXXX)"
trap 'rm -rf -- "$STAGING"' EXIT
APP="$STAGING/Lightpaw.app"
FINAL="dist/Lightpaw.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --show-sdk-path)"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" -sdk "$SDK" -module-cache-path .build/module-cache Sources/BrandMark.swift Scripts/CreateIcon.swift -framework AppKit -o "$STAGING/CreateIcon"
"$STAGING/CreateIcon" Resources/MacCare.icns
cp Resources/MacCare.icns "$APP/Contents/Resources/MacCare.icns"
xcrun clang -O2 -Wall -Wextra -mmacosx-version-min=13.0 -isysroot "$SDK" -c Sources/Monitor.c -o .build/Monitor.o
xcrun clang -O2 -Wall -Wextra -mmacosx-version-min=13.0 -isysroot "$SDK" Sources/MoleGuardian.c -o "$APP/Contents/MacOS/MoleGuardian"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" -sdk "$SDK" -module-cache-path .build/module-cache Sources/Helpers/MacCareAskpass.swift -framework AppKit -o "$APP/Contents/MacOS/MacCareAskpass"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" -sdk "$SDK" -module-cache-path .build/module-cache -import-objc-header Sources/Monitor.h Sources/*.swift Sources/Models/*.swift Sources/Views/*.swift .build/Monitor.o -framework AppKit -framework SwiftUI -framework Foundation -lproc -o "$APP/Contents/MacOS/CodexMemoryWatch"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codex.memorywatch</string>
<key>CFBundleName</key><string>Lightpaw</string>
<key>CFBundleDisplayName</key><string>Lightpaw</string>
<key>CFBundleExecutable</key><string>CodexMemoryWatch</string>
<key>CFBundleIconFile</key><string>MacCare</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>4.4.0</string>
<key>CFBundleVersion</key><string>25</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><false/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/MacOS/MoleGuardian"
codesign --force --sign - "$APP/Contents/MacOS/MacCareAskpass"
codesign --force --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
if [ -d "$FINAL" ]; then rm -rf -- "$FINAL"; fi
mv "$APP" "$FINAL"
printf 'Built: %s\n' "$PWD/$FINAL"
