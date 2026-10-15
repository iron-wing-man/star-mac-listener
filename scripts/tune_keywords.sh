#!/bin/bash

# tune_keywords.sh - Analyze wake word triggers and optimize keywords.txt based on user feedback
# Usage: ./scripts/tune_keywords.sh [--apply]

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSONL_FILE="${BASE_DIR}/config/wake_events.jsonl"
KEYWORDS_FILE="${BASE_DIR}/config/keywords.txt"

echo "======================================================"
echo "🎯 STAR Stella Wakeword Phoneme Tuner & Analyzer"
echo "======================================================"

if [ ! -f "${JSONL_FILE}" ]; then
    echo "⚠️ No wake events logged yet at ${JSONL_FILE}."
    exit 0
fi

TOTAL_EVENTS=$(grep -c '^{' "${JSONL_FILE}" 2>/dev/null) || TOTAL_EVENTS=0
CORRECT_COUNT=$(grep -c '"feedback":"correct"' "${JSONL_FILE}" 2>/dev/null) || CORRECT_COUNT=0
FALSE_COUNT=$(grep -c '"feedback":"false_trigger"' "${JSONL_FILE}" 2>/dev/null) || FALSE_COUNT=0
UNLABELED_COUNT=$(grep -c '"feedback":"unlabeled"' "${JSONL_FILE}" 2>/dev/null) || UNLABELED_COUNT=0

echo "📊 Event Summary:"
echo "   Total Triggers:    ${TOTAL_EVENTS}"
echo "   👍 Correct:        ${CORRECT_COUNT}"
echo "   👎 False Triggers: ${FALSE_COUNT}"
echo "   ⏳ Unlabeled:      ${UNLABELED_COUNT}"
echo ""

echo "🏆 Top Verified Phoneme Rules (Marked as Correct):"
if [ "${CORRECT_COUNT}" -gt 0 ]; then
    grep '"feedback":"correct"' "${JSONL_FILE}" | sed -E 's/.*"tokenString":"([^"]+)".*"keyword":"([^"]+)".*/\1 @\2/' | sort | uniq -c | sort -nr
else
    echo "   (None marked correct yet. Click '👍 標記為：正確喚醒' in Menu Bar when triggered!)"
fi
echo ""

echo "⚠️ False Trigger Phoneme Rules (Marked as False Trigger):"
if [ "${FALSE_COUNT}" -gt 0 ]; then
    grep '"feedback":"false_trigger"' "${JSONL_FILE}" | sed -E 's/.*"tokenString":"([^"]+)".*"keyword":"([^"]+)".*/\1 @\2/' | sort | uniq -c | sort -nr
else
    echo "   (None marked false trigger yet. Click '👎 標記為：誤觸' in Menu Bar when false wake occurs!)"
fi
echo ""

if [ "$1" == "--apply" ]; then
    echo "🛠️ Creating optimized backup and recommendations..."
    cp "${KEYWORDS_FILE}" "${KEYWORDS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo "✅ Backup created at ${KEYWORDS_FILE}.bak"
fi

echo "Tip: As you accumulate 20-50 triggers, run this script to see which phoneme pronunciations match your natural speech pattern best!"
