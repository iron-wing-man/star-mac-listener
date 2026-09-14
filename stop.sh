#!/bin/bash
echo "🛑 停止 StarListener..."
pkill -f "StarListener.app/Contents/MacOS/StarListener"
pkill -f "sherpa-onnx-keyword-spotter"
echo "✅ 已停止 StarListener 及相關監聽進程。"
