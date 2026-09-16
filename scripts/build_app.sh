#!/bin/bash

# build_app.sh - Compile the Swift app and create the App Bundle

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${BASE_DIR}/StarListener.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building StarListener Menu Bar App..."

# 1. 建立目錄結構
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 2. 複製 App Icon
if [ -f "${BASE_DIR}/assets/AppIcon.icns" ]; then
    cp "${BASE_DIR}/assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
    echo "✅ AppIcon.icns added to bundle."
fi

# 3. 編譯 Swift 程式碼
echo "Compiling Swift source files..."
swiftc -o "${MACOS_DIR}/StarListener" "${BASE_DIR}/src/"*.swift
if [ $? -ne 0 ]; then
    echo "❌ Swift compilation failed."
    exit 1
fi

# 4. 建立 Info.plist (包含 LSUIElement、CFBundleIconFile 和 Microphone 權限)
echo "Generating Info.plist..."
cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>StarListener</string>
    <key>CFBundleIdentifier</key>
    <string>com.jasper.starlistener</string>
    <key>CFBundleName</key>
    <string>StarListener</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>需要存取本地網絡以連線至 star-service 伺服器。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>需要使用麥克風來監聽廣東話喚醒詞「星仔」。</string>
</dict>
</plist>
EOF

# 5. 對整個 App Bundle 進行代碼簽名 (Code Signing)
# ⚠️ 必須執行 codesign 密封 bundle，否則 macOS TCC 會判定簽名損壞，導致每次啟動都重問麥克風權限
echo "Signing StarListener.app bundle..."
codesign --force --deep -s - "${APP_DIR}"

echo "✅ Build completed successfully! App bundle is at ${APP_DIR}"
