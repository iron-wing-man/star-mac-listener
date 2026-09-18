#!/usr/bin/env bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$PROJECT_DIR/bin"
MODEL_DIR="$PROJECT_DIR/model"
CONFIG_DIR="$PROJECT_DIR/config"
OUTPUT_WAV="/tmp/star_sample.wav"

# 1. 暫停背景運行的監聽器，避免搶佔麥克風
"$PROJECT_DIR/stop.sh" >/dev/null 2>&1 || true

echo "=================================================="
echo "🎙️  StarListener 喚醒詞錄音與離線驗證工具"
echo "=================================================="
echo ""
echo "即將開始錄音..."
echo "倒數 3 秒後會響起「叮 (Ping)」一聲，"
echo "聽到提示音後，請用正常說話音量清晰講出：「Stella」（講兩次，例如：Stella...Stella）"
echo "錄音持續 5 秒，結束時會響起「玻璃聲 (Glass)」提示音。"
echo "=================================================="
echo ""

# 倒數計時與語音提示
for i in 3 2 1; do
    echo "倒數: $i..."
    /usr/bin/say "$i" 2>/dev/null || true
    sleep 0.5
done

# 開始提示音
afplay /System/Library/Sounds/Ping.aiff 2>/dev/null || true
echo "🔴 【錄音中 (5秒)】請清晰講出：「Stella」..."

# 錄音 5 秒 16kHz 16-bit mono WAV
/opt/homebrew/bin/ffmpeg -y -loglevel error -f avfoundation -i ":0" -t 5 -ar 16000 -ac 1 "$OUTPUT_WAV"

# 結束提示音
afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true
echo "🟢 【錄音完畢】檔案儲存於: $OUTPUT_WAV"
ls -lh "$OUTPUT_WAV"
echo ""

# 檢查錄音音量
VOL_INFO=$(/opt/homebrew/bin/ffmpeg -i "$OUTPUT_WAV" -af "volumedetect" -vn -sn -dn -f null /dev/null 2>&1 | grep "max_volume" || true)
echo "音量檢測: $VOL_INFO"

echo ""
echo "=================================================="
echo "🔍 正在以離線 Zipformer 模型進行喚醒詞比對..."
echo "=================================================="

# 測試不同門檻值 (threshold 0.05, 0.03, 0.02, 0.01)
THRESHOLDS=("0.05" "0.03" "0.02" "0.01")
WINNING_TH=""

for th in "${THRESHOLDS[@]}"; do
    echo "----------------------------------------"
    echo "測試門檻 threshold = $th (score = 2.0):"
    
    RESULT=$("$BIN_DIR/sherpa-onnx-keyword-spotter" \
        --tokens="$MODEL_DIR/tokens.txt" \
        --encoder="$MODEL_DIR/encoder.onnx" \
        --decoder="$MODEL_DIR/decoder.onnx" \
        --joiner="$MODEL_DIR/joiner.onnx" \
        --keywords-file="$CONFIG_DIR/keywords.txt" \
        --keywords-threshold="$th" \
        --keywords-score=2.0 \
        --max-active-paths=16 \
        "$OUTPUT_WAV" 2>&1 || true)
    
    DETECTIONS=$(echo "$RESULT" | grep '{"start_time"' || true)
    
    if [ -n "$DETECTIONS" ]; then
        echo "🎉 成功偵測到喚醒詞！"
        echo "$DETECTIONS"
        WINNING_TH="$th"
        break
    else
        echo "❌ 未能在此門檻 ($th) 觸發。"
    fi
done

echo ""
echo "=================================================="
if [ -n "$WINNING_TH" ]; then
    echo "✅ 驗證成功！模型成功從你的真實錄音識別出「Stella」！"
    echo "💡 最佳實測 threshold: $WINNING_TH"
    echo ""
    echo "➡️ 自動將最佳參數套用至 StarListener 並重啟..."
    
    # 自動更新 main.swift 門檻值
    sed -i '' "s/--keywords-threshold=[0-9.]*/--keywords-threshold=$WINNING_TH/" "$PROJECT_DIR/src/main.swift"
    sed -i '' "s/--keywords-score=[0-9.]*/--keywords-score=2.0/" "$PROJECT_DIR/src/main.swift"
    
    # 重新編譯與啟動
    "$PROJECT_DIR/scripts/build_app.sh" >/dev/null 2>&1
    "$PROJECT_DIR/start.sh" >/dev/null 2>&1
    echo "🚀 StarListener 已使用 threshold=$WINNING_TH 重新編譯並上線運行！"
else
    echo "⚠️ 暫時未能識別出「Stella」。"
    echo "請確認剛才錄音時是否有聽到「叮」聲並清晰對住 Mac 麥克風講「Stella」。"
fi
echo "=================================================="
