#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

app_dir="$project_dir/build/PodCharge.app"
contents="$app_dir/Contents"
rm -rf "$app_dir"
mkdir -p "$contents/MacOS" "$contents/Resources"

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PodCharge</string>
  <key>CFBundleIdentifier</key><string>org.podcharge.local</string>
  <key>CFBundleName</key><string>PodCharge</string>
  <key>CFBundleDisplayName</key><string>PodCharge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>PodCharge reads nearby AirPods battery information locally.</string>
</dict></plist>
PLIST

cat > "$project_dir/build/PodCharge.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.device.bluetooth</key><true/>
</dict></plist>
PLIST

swiftc -O -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o "$contents/MacOS/PodCharge"
codesign --force --sign - --options runtime --entitlements "$project_dir/build/PodCharge.entitlements" "$app_dir"
codesign --verify --strict --verbose=2 "$app_dir"
echo "Built $app_dir"
