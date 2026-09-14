#!/bin/bash
set -e

# download_deps.sh - Download Sherpa-ONNX binary and KWS model

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${BASE_DIR}/bin"
MODEL_DIR="${BASE_DIR}/model"
CONFIG_DIR="${BASE_DIR}/config"

mkdir -p "${BIN_DIR}" "${MODEL_DIR}" "${CONFIG_DIR}"

echo "Downloading dependencies..."

# 1. Download Sherpa-ONNX standalone static binary for macOS arm64
echo "1. Downloading Sherpa-ONNX binaries (v1.13.8)..."
cd /tmp
curl -SL -O https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-static.tar.bz2
tar xjf sherpa-onnx-v1.13.8-osx-arm64-static.tar.bz2

# Copy microphone live spotter & offline WAV spotter
cp sherpa-onnx-v1.13.8-osx-arm64-static/bin/sherpa-onnx-keyword-spotter-microphone "${BIN_DIR}/"
cp sherpa-onnx-v1.13.8-osx-arm64-static/bin/sherpa-onnx-keyword-spotter "${BIN_DIR}/"
chmod +x "${BIN_DIR}/sherpa-onnx-keyword-spotter-microphone" "${BIN_DIR}/sherpa-onnx-keyword-spotter"
echo "✅ Binaries installed."

# 2. Download Chinese KWS Model (WenetSpeech 3.3M)
echo "2. Downloading KWS model..."
cd /tmp
curl -SL -O https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2
tar xjf sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2

MODEL_SRC="/tmp/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01"
cp "${MODEL_SRC}/tokens.txt" "${MODEL_DIR}/"
cp "${MODEL_SRC}/encoder-epoch-12-avg-2-chunk-16-left-64.onnx" "${MODEL_DIR}/encoder.onnx"
cp "${MODEL_SRC}/decoder-epoch-12-avg-2-chunk-16-left-64.onnx" "${MODEL_DIR}/decoder.onnx"
cp "${MODEL_SRC}/joiner-epoch-12-avg-2-chunk-16-left-64.onnx" "${MODEL_DIR}/joiner.onnx"
echo "✅ Model installed."

# 3. Create default keywords.txt if not exists
if [ ! -f "${CONFIG_DIR}/keywords.txt" ]; then
    echo "3. Creating default config/keywords.txt..."
    cat <<EOF > "${CONFIG_DIR}/keywords.txt"
sh ēng z ài @星仔
sh ēng z ǎi @星仔
sh ēng z āi @星仔
sh ēng z ǐ @星仔
s īng z ài @星仔
s īng z ǎi @星仔
s īng z ǐ @星仔
s ēng z ài @星仔
s ēng z ǎi @星仔
x īng z ài @星仔
x īng z ǎi @星仔
x īng z ǐ @星仔
n ǐ h ǎo sh ēng z ài @你好星仔
n ǐ h ǎo s īng z ǎi @你好星仔
n ǐ h ǎo x īng z ǎi @你好星仔
EOF
    echo "✅ Configuration created."
else
    echo "ℹ️ config/keywords.txt already exists, skipping overwrite."
fi

# Clean up
rm -rf /tmp/sherpa-onnx-*

echo "🎉 All dependencies downloaded and set up successfully!"
