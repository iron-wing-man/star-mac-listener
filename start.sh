#!/bin/bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 檢查是否已經運行中
if pgrep -f "StarListener.app/Contents/MacOS/StarListener" > /dev/null; then
    echo "⚠️  StarListener 已經在運行中！"
    exit 0
fi

echo "🚀 啟動 StarListener..."
open "${BASE_DIR}/StarListener.app"
echo "✅ 已啟動！請留意螢幕右上角 Menu Bar（時鐘附近）的 ☆ 圖標。"
