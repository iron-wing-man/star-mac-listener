#!/usr/bin/env bash
# ==============================================================================
# Quality Check Script for STAR Mac Listener
# Performs Swift typecheck and validates architectural invariants
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "======================================"
echo "🌟 STAR Mac Listener Quality Check 🌟"
echo "======================================"

cd "$ROOT_DIR"

if [[ "${SKIP_LINT:-0}" == "1" ]]; then
    echo "⏭️ SKIP_LINT=1 detected. Skipping quality checks."
    exit 0
fi

# 1. Swift Typecheck & Syntax Check
echo -e "\n[1/2] 🍎 Checking Swift source files (swiftc typecheck)..."
swiftc -typecheck src/*.swift
echo "✅ Swift typecheck passed!"

# 2. Critical Architectural Invariants Check
echo -e "\n[2/2] 🛡️ Checking critical architectural invariants..."

# Invariant 1: STDERR pipe connection in main.swift
if ! grep -q "process?\.standardError = pipe" src/main.swift; then
    echo "❌ Violation: Invariant 1 - process.standardError must connect to pipe (sherpa outputs JSON to STDERR)!"
    exit 1
fi

# Invariant 2: Microphone keyword spotter binary
if ! grep -q "sherpa-onnx-keyword-spotter-microphone" src/main.swift; then
    echo "❌ Violation: Invariant 2 - Must use sherpa-onnx-keyword-spotter-microphone!"
    exit 1
fi

# Invariant 3: Keywords threshold and max active paths
if ! grep -q "\-\-max-active-paths=16" src/main.swift || ! grep -q "\-\-keywords-threshold=0.06" src/main.swift; then
    echo "❌ Violation: Invariant 4 - Must set --max-active-paths=16 and --keywords-threshold=0.06!"
    exit 1
fi

# Invariant 4: Info.plist requirements in build script
if ! grep -q "NSMicrophoneUsageDescription" scripts/build_app.sh || ! grep -q "LSUIElement" scripts/build_app.sh; then
    echo "❌ Violation: Invariant 5 - Info.plist must include NSMicrophoneUsageDescription and LSUIElement!"
    exit 1
fi

echo "✅ All critical architectural invariants verified!"
echo -e "\n🎉 Quality check completed successfully."
