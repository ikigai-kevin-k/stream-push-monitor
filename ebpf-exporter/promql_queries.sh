#!/bin/bash
# PromQL API 查詢範例腳本

PROMETHEUS_HOST=${1:-localhost}
PROMETHEUS_PORT=${2:-9090}
EXPORTER_HOST=${3:-localhost}
EXPORTER_PORT=${4:-9310}

echo "=========================================="
echo "PromQL API 查詢範例"
echo "=========================================="
echo ""
echo "Prometheus 伺服器: http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}"
echo "Exporter 端點: http://${EXPORTER_HOST}:${EXPORTER_PORT}"
echo ""

# 1. 直接查詢 Exporter 的 metrics 端點
echo "=========================================="
echo "1. 直接查詢 Exporter Metrics 端點"
echo "=========================================="
echo ""
echo "命令：curl http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics"
echo ""
curl -s http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics | grep -i jitterbuffer | head -20
echo ""

# 2. 查詢 Prometheus API - 所有 jitterbuffer metrics
echo "=========================================="
echo "2. PromQL: 查詢所有 jitterbuffer metrics"
echo "=========================================="
echo ""
echo "命令：curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query' --data-urlencode 'query={__name__=~\"jitterbuffer.*\"}'"
echo ""
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
    --data-urlencode 'query={__name__=~"jitterbuffer.*"}' | jq '.data.result[] | {metric: .metric, value: .value}' 2>/dev/null || \
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
    --data-urlencode 'query={__name__=~"jitterbuffer.*"}'
echo ""

# 3. 查詢封包計數
echo "=========================================="
echo "3. PromQL: 查詢封包計數"
echo "=========================================="
echo ""
echo "命令：curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query' --data-urlencode 'query=jitterbuffer_packet_count_total'"
echo ""
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
    --data-urlencode 'query=jitterbuffer_packet_count_total' | jq '.data.result[] | {metric: .metric, value: .value}' 2>/dev/null || \
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
    --data-urlencode 'query=jitterbuffer_packet_count_total'
echo ""

# 4. 查詢平均延遲
echo "=========================================="
echo "4. PromQL: 查詢平均延遲"
echo "=========================================="
echo ""
echo "命令：curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query' --data-urlencode 'query=jitterbuffer_delay_avg_seconds'"
echo ""
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
    --data-urlencode 'query=jitterbuffer_delay_avg_seconds' | jq '.data.result[] | {metric: .metric, value: .value}' 2>/dev/null || \
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query" \
    --data-urlencode 'query=jitterbuffer_delay_avg_seconds'
echo ""

# 5. 查詢延遲分佈（使用 range query）
echo "=========================================="
echo "5. PromQL: 查詢延遲分佈（Range Query）"
echo "=========================================="
echo ""
echo "命令：curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/query_range' --data-urlencode 'query=rate(jitterbuffer_delay_seconds_bucket[5m])' --data-urlencode 'start=<timestamp>' --data-urlencode 'end=<timestamp>' --data-urlencode 'step=15s'"
echo ""
echo "（需要提供 start、end、step 參數）"
echo ""

# 6. 查詢所有標籤
echo "=========================================="
echo "6. PromQL: 查詢所有標籤"
echo "=========================================="
echo ""
echo "命令：curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/labels'"
echo ""
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/labels" | jq '.data[]' 2>/dev/null || \
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/labels"
echo ""

# 7. 查詢特定標籤的值
echo "=========================================="
echo "7. PromQL: 查詢標籤值（例如：function）"
echo "=========================================="
echo ""
echo "命令：curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/label/function/values'"
echo ""
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/label/function/values" | jq '.data[]' 2>/dev/null || \
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/label/function/values"
echo ""

# 8. 檢查 Prometheus 目標狀態
echo "=========================================="
echo "8. 檢查 Prometheus 目標狀態"
echo "=========================================="
echo ""
echo "命令：curl -G 'http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/targets'"
echo ""
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job == "ffmpeg-jitterbuffer") | {job: .labels.job, health: .health, lastScrape: .lastScrape}' 2>/dev/null || \
curl -s -G "http://${PROMETHEUS_HOST}:${PROMETHEUS_PORT}/api/v1/targets"
echo ""

