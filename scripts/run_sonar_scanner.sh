#!/usr/bin/env bash
# ==============================================================================
# Run SonarQube Scanner for STAR Mac Listener
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "======================================"
echo "🌟 STAR Mac Listener Sonar Scanner 🌟"
echo "======================================"

# 1. 載入 .env
if [ -f "$ROOT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
fi

SONAR_HOST_URL="${SONAR_HOST_URL:-http://localhost:9000}"

if [ -z "${SONAR_TOKEN:-}" ]; then
    echo "❌ Error: SONAR_TOKEN is not configured."
    echo "💡 Please add SONAR_TOKEN=your_token to $ROOT_DIR/.env"
    exit 1
fi

# 2. 檢查連線
if ! curl -s --connect-timeout 3 "$SONAR_HOST_URL/api/system/status" > /dev/null; then
    echo "⚠️ Warning: SonarQube server at $SONAR_HOST_URL is not reachable. Skipping scan."
    exit 0
fi

# 3. 檢查 sonar-scanner CLI
if ! command -v sonar-scanner &> /dev/null; then
    echo "❌ Error: sonar-scanner CLI not found on this machine."
    echo "💡 Install it via Homebrew: brew install sonar-scanner"
    exit 1
fi

# 4. 執行 SonarQube Scanner
echo -e "\n🚀 Launching sonar-scanner..."
cd "$ROOT_DIR"
sonar-scanner \
    -Dsonar.host.url="$SONAR_HOST_URL" \
    -Dsonar.token="$SONAR_TOKEN"

echo -e "\n✅ SonarQube scan completed!"
echo "🔗 View dashboard: $SONAR_HOST_URL/dashboard?id=star-mac-listener"
