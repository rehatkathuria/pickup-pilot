#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p work outputs
export CLANG_MODULE_CACHE_PATH="$PWD/work/clang-cache"
BUILD_DIRECTORY="$PWD/work/app-build"
swift build --disable-sandbox --build-system native --scratch-path "$BUILD_DIRECTORY" -c release
BINARY_DIRECTORY=$(swift build --disable-sandbox --build-system native --scratch-path "$BUILD_DIRECTORY" -c release --show-bin-path)
PILOT_STAGE_DIRECTORY=$(mktemp -d /private/tmp/pickup-pilot-build.XXXXXX)
trap 'rm -rf -- "$PILOT_STAGE_DIRECTORY"' EXIT
APP_DIRECTORY="$PILOT_STAGE_DIRECTORY/Pickup Pilot.app"
mkdir -p "$APP_DIRECTORY/Contents/MacOS" "$APP_DIRECTORY/Contents/Resources"
cp "$BINARY_DIRECTORY/PickupPilot" "$APP_DIRECTORY/Contents/MacOS/PickupPilot"
cat > "$APP_DIRECTORY/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Pickup Pilot</string>
<key>CFBundleDisplayName</key><string>Pickup Pilot</string>
<key>CFBundleIdentifier</key><string>local.pickuppilot.app</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>PickupPilot</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSLocationUsageDescription</key><string>Suggest nearby Apple retail stores in your current country for iPhone pickup. You can enter a country and location manually instead.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Suggest nearby Apple retail stores in your current country for iPhone pickup. You can enter a country and location manually instead.</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Automate guest checkout in the dedicated Safari window created by Pickup Pilot. Other Safari windows are not controlled.</string>
</dict></plist>
PLIST
xattr -cr "$APP_DIRECTORY"
codesign --force --sign - --identifier local.pickuppilot.app --timestamp=none "$APP_DIRECTORY"
codesign --verify --strict "$APP_DIRECTORY"
python3 scripts/package-app.py --app "$APP_DIRECTORY"
printf '%s\n' "Built $PWD/outputs/Pickup Pilot.app and metadata-free ZIP"
