#!/bin/bash
# PromQL API 查詢測試腳本

PROMETHEUS_HOST=${1:-localhost}
PROMETHEUS_PORT=${2:-9090}
EXPORTER_HOST=${3:-localhost}
EXPORTER_PORT=${4:-9310}

echo "=========================================="
echo "PromQL API 查詢測試"
echo "=========================================="
echo ""
echo "Prometheus: http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}"
echo "Exporter: http://${EXPORTER_HOST}:${EXPORTER_PORT}"
echo ""

# 檢查 Prometheus 是否運行
echo "1. 檢查 Prometheus 是否運行..."
if curl -s "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/status/config" > /dev/null 2>&1; then
    echo "   ✓ Prometheus 正在運行"
    PROMETHEUS_AVAILABLE=1
else
    echo "   ✗ Prometheus 未運行（將只查詢 Exporter 端點）"
    PROMETHEUS_AVAILABLE=0
fi
echo ""

# 檢查 Exporter 是否運行
echo "2. 檢查 Exporter 是否運行..."
if curl -s "http://${EXPORTER_HOST}:${EXPORTER_PORT}/health" > /dev/null 2>&1; then
    echo "   ✓ Exporter 正在運行"
    EXPORTER_AVAILABLE=1
else
    echo "   ✗ Exporter 未運行"
    exit 1
fi
echo ""

# 直接查詢 Exporter
echo "3. 直接查詢 Exporter Metrics（包含實際數據的 metrics）..."
echo ""
JITTER_METRICS=$(curl -s "http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics" | grep -E '^jitterbuffer[^#]' | head -10)
if [ -n "$JITTER_METRICS" ]; then
    echo "   找到 jitterbuffer 數據："
    echo "$JITTER_METRICS" | sed 's/^/   /'
else
    echo "   ⚠ 沒有找到 jitterbuffer 數據（只有定義，沒有實際值）"
    echo "   這表示 probes 可能沒有成功附加或沒有數據產生"
fi
echo ""

# 如果 Prometheus 可用，進行 PromQL 查詢
if [ "$PROMETHEUS_AVAILABLE" = "1" ]; then
    echo "4. PromQL 查詢（需要 Prometheus 已配置並抓取此 exporter）..."
    echo ""
    
    # 查詢所有 jitterbuffer metrics
    echo "   a) 查詢所有 jitterbuffer metrics："
    echo "      curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query' --data-urlencode 'query={__name__=~\"jitterbuffer.*\"}'"
    echo ""
    RESULT=$(curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
        --data-urlencode 'query={__name__=~"jitterbuffer.*"}')
    
    if echo "$RESULT" | jq -e '.data.result | length > 0' > /dev/null 2>&1; then
        echo "   結果："
        echo "$RESULT" | jq -r '.data.result[] | "   \(.metric.__name__) = \(.value[1])"' 2>/dev/null || echo "$RESULT"
    else
        echo "   ⚠ 沒有找到數據（可能 Prometheus 還沒有抓取，或 exporter 沒有數據）"
        echo "   狀態：$(echo "$RESULT" | jq -r '.status' 2>/dev/null || echo 'unknown')"
    fi
    echo ""
    
    # 查詢封包計數
    echo "   b) 查詢封包計數："
    echo "      curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query' --data-urlencode 'query=jitterbuffer_packet_count_total'"
    echo ""
    RESULT=$(curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
        --data-urlencode 'query=jitterbuffer_packet_count_total')
    
    if echo "$RESULT" | jq -e '.data.result | length > 0' > /dev/null 2>&1; then
        echo "   結果："
        echo "$RESULT" | jq -r '.data.result[] | "   \(.metric) = \(.value[1])"' 2>/dev/null || echo "$RESULT"
    else
        echo "   ⚠ 沒有數據"
    fi
    echo ""
    
    # 檢查目標狀態
    echo "   c) 檢查 Prometheus 目標狀態："
    echo "      curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/targets'"
    echo ""
    TARGETS=$(curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/targets")
    JITTER_TARGET=$(echo "$TARGETS" | jq -r '.data.activeTargets[] | select(.labels.job == "ffmpeg-jitterbuffer")' 2>/dev/null)
    
    if [ -n "$JITTER_TARGET" ]; then
        echo "   找到 ffmpeg-jitterbuffer 目標："
        echo "$JITTER_TARGET" | jq -r '"   Job: \(.labels.job), Health: \(.health), Last Scrape: \(.lastScrape)"' 2>/dev/null
    else
        echo "   ⚠ 沒有找到 ffmpeg-jitterbuffer 目標"
        echo "   請確認 prometheus.yml 中已配置此 job"
    fi
    echo ""
else
    echo "4. 跳過 PromQL 查詢（Prometheus 未運行）"
    echo ""
fi

# 總結
echo "=========================================="
echo "總結"
echo "=========================================="
echo ""
echo "如果沒有看到數據，可能的原因："
echo "1. FFmpeg 沒有運行或沒有推流活動"
echo "2. Uprobe 沒有成功附加（檢查函數名稱）"
echo "3. Prometheus 還沒有抓取數據（需要配置並等待）"
echo ""
echo "檢查方法："
echo "1. 查看 exporter 日誌中的警告"
echo "2. 檢查 FFmpeg 進程：ps aux | grep ffmpeg"
echo "3. 檢查函數名稱：objdump -T /usr/bin/ffmpeg | grep -i jitter"
echo "4. 檢查 Prometheus 配置：確認 prometheus.yml 包含 ffmpeg-jitterbuffer job"
echo ""

