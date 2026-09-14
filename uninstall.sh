#!/bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🗑️ Stopping any running StarListener process..."
pkill -f "StarListener"
pkill -f "sherpa-onnx-keyword-spotter"

echo "🧹 Removing project files..."
rm -rf "${BASE_DIR}/StarListener.app"
rm -rf "${BASE_DIR}/bin"/*
rm -rf "${BASE_DIR}/model"/*

echo "✅ Uninstalled successfully!"
