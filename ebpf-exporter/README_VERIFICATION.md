# Metrics 驗證指南

## 快速驗證方法

### 方法 1: 直接查詢 Exporter Metrics 端點

```bash
# 查詢所有 metrics
curl http://localhost:9310/metrics

# 只查詢 jitterbuffer 相關 metrics
curl http://localhost:9310/metrics | grep jitterbuffer

# 檢查健康狀態
curl http://localhost:9310/health
```

### 方法 2: 使用驗證腳本

```bash
# 使用預設端口 9310
./ebpf-exporter/verify_metrics.sh

# 指定自定義端口
./ebpf-exporter/verify_metrics.sh 9310 localhost
```

### 方法 3: 使用 PromQL API（如果有 Prometheus 伺服器）

#### 基本查詢

```bash
# 查詢所有 jitterbuffer metrics
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query={__name__=~"jitterbuffer.*"}'

# 查詢封包計數
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total'

# 查詢平均延遲
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_delay_avg_seconds'

# 查詢最小延遲
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_delay_min_seconds'

# 查詢最大延遲
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_delay_max_seconds'

# 查詢丟棄的封包數
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_dropped_packets_total'

# 查詢處理的位元組數
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_bytes_total'
```

#### 使用 Range Query（時間序列查詢）

```bash
# 獲取當前時間戳（Unix 時間戳）
START=$(date -d '5 minutes ago' +%s)
END=$(date +%s)

# 查詢過去 5 分鐘的封包計數變化
curl -G 'http://localhost:9090/api/v1/query_range' \
    --data-urlencode 'query=rate(jitterbuffer_packet_count_total[5m])' \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode 'step=15s'
```

#### 使用 jq 格式化輸出

```bash
# 安裝 jq（如果沒有）
sudo apt-get install -y jq

# 查詢並格式化輸出
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total' | \
    jq '.data.result[] | {metric: .metric, value: .value[1]}'
```

#### 使用 PromQL 腳本

```bash
# 執行完整的 PromQL 查詢腳本
./ebpf-exporter/promql_queries.sh

# 指定自定義端口
./ebpf-exporter/promql_queries.sh localhost 9090 localhost 9310
```

## 預期的 Metrics 列表

當 exporter 正常運行並收集到數據時，應該能看到以下 metrics：

1. **jitterbuffer_packet_count_total** - 處理的封包總數
2. **jitterbuffer_delay_avg_seconds** - 平均延遲（秒）
3. **jitterbuffer_delay_min_seconds** - 最小延遲（秒）
4. **jitterbuffer_delay_max_seconds** - 最大延遲（秒）
5. **jitterbuffer_dropped_packets_total** - 丟棄的封包總數
6. **jitterbuffer_bytes_total** - 處理的位元組總數
7. **jitterbuffer_buffer_size_packets** - Buffer 大小（封包數）
8. **jitterbuffer_delay_seconds** - 延遲分佈（Histogram）

## 常見問題

### 問題 1: 沒有 metrics 數據

**可能原因：**
- FFmpeg 沒有運行或沒有推流活動
- 函數名稱不匹配（需要檢查實際的函數名稱）
- Uprobe 沒有成功附加

**解決方法：**
```bash
# 檢查 FFmpeg 是否在運行
ps aux | grep ffmpeg

# 檢查函數名稱
objdump -T /usr/bin/ffmpeg | grep -i jitter

# 檢查 exporter 日誌（查看是否有警告）
```

### 問題 2: Prometheus 無法抓取數據

**檢查方法：**
```bash
# 檢查 Prometheus 目標狀態
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job == "ffmpeg-jitterbuffer")'

# 檢查 Prometheus 配置
# 確認 prometheus.yml 中包含了正確的 scrape_config
```

### 問題 3: 查詢返回空結果

**可能原因：**
- Metrics 還沒有收集到數據（需要等待一段時間）
- Prometheus 還沒有抓取到數據
- 查詢語法錯誤

**解決方法：**
```bash
# 先直接查詢 exporter
curl http://localhost:9310/metrics | grep jitterbuffer

# 如果 exporter 有數據，檢查 Prometheus 是否抓取到
# 在 Prometheus Web UI 中查看：http://localhost:9090/targets
```

## 進階查詢範例

### 計算封包處理速率

```bash
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=rate(jitterbuffer_packet_count_total[5m])'
```

### 計算平均延遲的 95 百分位數

```bash
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=histogram_quantile(0.95, rate(jitterbuffer_delay_seconds_bucket[5m]))'
```

### 查詢特定 PID 的 metrics

```bash
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total{pid="12345"}'
```

### 查詢特定函數的 metrics

```bash
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total{function="jitterbuffer_put"}'
```

