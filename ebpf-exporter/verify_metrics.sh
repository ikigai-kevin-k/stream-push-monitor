#!/bin/bash
# 驗證 JitterBuffer Monitor Metrics 的腳本

EXPORTER_PORT=${1:-9310}
EXPORTER_HOST=${2:-localhost}

echo "=========================================="
echo "JitterBuffer Monitor Metrics 驗證"
echo "=========================================="
echo ""

# 1. 檢查健康狀態
echo "1. 檢查健康狀態："
echo "   curl http://${EXPORTER_HOST}:${EXPORTER_PORT}/health"
echo ""
curl -s http://${EXPORTER_HOST}:${EXPORTER_PORT}/health | jq '.' 2>/dev/null || curl -s http://${EXPORTER_HOST}:${EXPORTER_PORT}/health
echo ""
echo ""

# 2. 檢查所有 metrics
echo "2. 檢查所有 Metrics："
echo "   curl http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics"
echo ""
curl -s http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics | head -50
echo ""
echo ""

# 3. 檢查 jitterbuffer 相關 metrics
echo "3. 檢查 JitterBuffer 相關 Metrics："
echo "   curl http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics | grep jitterbuffer"
echo ""
curl -s http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics | grep -i jitterbuffer || echo "   (沒有找到 jitterbuffer metrics，可能還沒有數據)"
echo ""
echo ""

# 4. 檢查 Prometheus 格式
echo "4. 檢查 Prometheus 格式是否正確："
METRICS_COUNT=$(curl -s http://${EXPORTER_HOST}:${EXPORTER_PORT}/metrics | grep -v '^#' | wc -l)
echo "   找到 $METRICS_COUNT 個 metrics"
echo ""

# 5. 如果有 Prometheus 伺服器，提供查詢範例
echo "5. PromQL 查詢範例（如果有 Prometheus 伺服器）："
echo ""
echo "   查詢所有 jitterbuffer metrics："
echo "   curl -G 'http://localhost:9090/api/v1/query' --data-urlencode 'query=jitterbuffer_packet_count_total'"
echo ""
echo "   查詢平均延遲："
echo "   curl -G 'http://localhost:9090/api/v1/query' --data-urlencode 'query=jitterbuffer_delay_avg_seconds'"
echo ""
echo "   查詢延遲分佈（Histogram）："
echo "   curl -G 'http://localhost:9090/api/v1/query' --data-urlencode 'query=histogram_quantile(0.95, rate(jitterbuffer_delay_seconds_bucket[5m]))'"
echo ""

