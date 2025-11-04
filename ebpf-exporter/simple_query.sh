#!/bin/bash
# 簡單的 PromQL API 查詢腳本

PROMETHEUS_HOST=${1:-localhost}
PROMETHEUS_PORT=${2:-9090}
EXPORTER_HOST=${3:-localhost}
EXPORTER_PORT=${4:-9310}

echo "=========================================="
echo "Metrics 查詢工具"
echo "=========================================="
echo ""

# 1. 檢查 Exporter 健康狀態
echo "1. 檢查 Exporter 健康狀態："
HEALTH=$(curl -s "http://${EXPORTER_HOST}:${EXPORTER_PORT}/health")
echo "$HEALTH" | jq '.' 2>/dev/null || echo "$HEALTH"
echo ""

# 2. 檢查 Exporter 是否有實際數據
echo "2. 檢查 Exporter Metrics（是否有實際數據）："
METRICS=$(curl -s "http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics")
DATA_LINES=$(echo "$METRICS" | grep -E '^jitterbuffer[^#]' | grep -v '^#' | wc -l)

if [ "$DATA_LINES" -gt 0 ]; then
    echo "   ✓ 找到 $DATA_LINES 個包含數據的 jitterbuffer metrics"
    echo "$METRICS" | grep -E '^jitterbuffer[^#]' | grep -v '^#' | head -5
else
    echo "   ⚠ 沒有找到包含數據的 jitterbuffer metrics"
    echo "   （只有定義，沒有實際值）"
fi
echo ""

# 3. PromQL 查詢（如果 Prometheus 可用）
echo "3. PromQL API 查詢："
echo ""

# 檢查 Prometheus 是否運行
if curl -s "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/status/config" > /dev/null 2>&1; then
    echo "   Prometheus 正在運行"
    
    # 查詢封包計數
    echo ""
    echo "   a) 查詢封包計數："
    RESULT=$(curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
        --data-urlencode 'query=jitterbuffer_packet_count_total')
    
    STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
    RESULT_COUNT=$(echo "$RESULT" | jq '.data.result | length' 2>/dev/null)
    
    if [ "$STATUS" = "success" ] && [ "$RESULT_COUNT" -gt 0 ]; then
        echo "   ✓ 找到 $RESULT_COUNT 個結果："
        echo "$RESULT" | jq -r '.data.result[] | "      \(.metric | to_entries | map("\(.key)=\"\(.value)\"") | join(",")) = \(.value[1])"' 2>/dev/null
    elif [ "$STATUS" = "success" ]; then
        echo "   ⚠ 查詢成功但沒有數據（result 為空）"
        echo "   這表示 Prometheus 還沒有抓取到數據，或 exporter 沒有產生數據"
    else
        echo "   ✗ 查詢失敗"
        echo "$RESULT" | jq '.' 2>/dev/null || echo "$RESULT"
    fi
    
    # 查詢平均延遲
    echo ""
    echo "   b) 查詢平均延遲："
    RESULT=$(curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
        --data-urlencode 'query=jitterbuffer_delay_avg_seconds')
    
    RESULT_COUNT=$(echo "$RESULT" | jq '.data.result | length' 2>/dev/null)
    
    if [ "$RESULT_COUNT" -gt 0 ]; then
        echo "   ✓ 找到 $RESULT_COUNT 個結果："
        echo "$RESULT" | jq -r '.data.result[] | "      \(.metric | to_entries | map("\(.key)=\"\(.value)\"") | join(",")) = \(.value[1])"' 2>/dev/null
    else
        echo "   ⚠ 沒有數據"
    fi
    
    # 檢查目標狀態
    echo ""
    echo "   c) 檢查 Prometheus 目標狀態："
    TARGETS=$(curl -s "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/targets")
    JITTER_TARGET=$(echo "$TARGETS" | jq '.data.activeTargets[] | select(.labels.job == "ffmpeg-jitterbuffer")' 2>/dev/null)
    
    if [ -n "$JITTER_TARGET" ] && [ "$JITTER_TARGET" != "null" ]; then
        echo "   ✓ 找到 ffmpeg-jitterbuffer 目標："
        echo "$JITTER_TARGET" | jq -r '"      Job: \(.labels.job), Health: \(.health), Last Scrape: \(.lastScrape)"' 2>/dev/null
    else
        echo "   ⚠ 沒有找到 ffmpeg-jitterbuffer 目標"
        echo "   請確認 prometheus.yml 中已配置此 job"
    fi
    
else
    echo "   Prometheus 未運行（跳過 PromQL 查詢）"
    echo ""
    echo "   直接查詢 Exporter："
    echo "   curl http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics | grep jitterbuffer"
fi

echo ""
echo "=========================================="
echo "總結"
echo "=========================================="
echo ""
echo "當前狀態："
echo "  - Exporter: $(if curl -s "http://${EXPORTER_HOST}:${EXPORTER_PORT}/health" > /dev/null 2>&1; then echo "✓ 運行中"; else echo "✗ 未運行"; fi)"
echo "  - Prometheus: $(if curl -s "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/status/config" > /dev/null 2>&1; then echo "✓ 運行中"; else echo "✗ 未運行"; fi)"
echo "  - 數據: $(if [ "$DATA_LINES" -gt 0 ]; then echo "✓ 有數據"; else echo "⚠ 無數據（需要修正 probes）"; fi)"
echo ""
echo "如果沒有數據，請："
echo "  1. 檢查 FFmpeg 函數名稱: objdump -T /usr/bin/ffmpeg | grep -i jitter"
echo "  2. 更新 exporter 中的函數名稱列表"
echo "  3. 確認 FFmpeg 正在運行並有推流活動"
echo ""

