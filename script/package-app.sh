#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AgentPulse"
BUNDLE_ID="com.agentpulse.app"
APP_VERSION="1.0.3"
DIST_DIR="$PWD/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_FILE="$PWD/Resources/AppIcon.icns"

HOME="$PWD/.swiftpm-home" \
SWIFTPM_HOME="$PWD/.swiftpm-home" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift build --disable-sandbox -c release \
    --cache-path "$PWD/.build/swiftpm-cache" \
    --config-path "$PWD/.build/swiftpm-config" \
    --security-path "$PWD/.build/swiftpm-security"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PWD/.build/release/AgentPulse" "$MACOS_DIR/$APP_NAME"
cp "$PWD/.build/release/agentpulse-cli" "$RESOURCES_DIR/agentpulse-cli"
chmod +x "$RESOURCES_DIR/agentpulse-cli"
if [[ -f "$ICON_FILE" ]]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSpokenName</key>
    <string>Agent Pulse</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 AgentPulse.</string>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/$APP_NAME"
codesign --force --deep --sign - "$APP_DIR"
echo "Created $APP_DIR"
