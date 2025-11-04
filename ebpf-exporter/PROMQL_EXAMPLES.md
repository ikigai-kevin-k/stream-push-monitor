# PromQL API 查詢範例

## 當前狀態說明

從您的終端輸出可以看到：
- ✅ Exporter 正常運行（健康檢查通過）
- ✅ Prometheus 正在運行（查詢返回成功）
- ⚠️ 沒有數據（`result: []` 表示空結果）

這是正常的，因為：
1. Uprobe 沒有成功附加（之前看到 "Warning: Could not attach any probes"）
2. 即使 metrics 定義已註冊，但沒有實際數據值
3. Prometheus 查詢成功，但結果為空（因為沒有數據）

## 快速查詢命令

### 方法 1: 使用簡單查詢腳本（推薦）

```bash
# 使用預設配置
./ebpf-exporter/simple_query.sh

# 自定義配置
./ebpf-exporter/simple_query.sh localhost 9090 localhost 9310
```

### 方法 2: 直接 PromQL API 查詢

#### 基本查詢語法

```bash
# 查詢封包計數
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total' | jq '.'

# 查詢平均延遲
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_delay_avg_seconds' | jq '.'

# 查詢所有 jitterbuffer metrics
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query={__name__=~"jitterbuffer.*"}' | jq '.'
```

#### 使用 jq 格式化輸出

```bash
# 安裝 jq（如果沒有）
sudo apt-get install -y jq

# 查詢並格式化
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total' | \
    jq '.data.result[] | {metric: .metric, value: .value[1], timestamp: .value[0]}'
```

#### 檢查查詢結果

```bash
# 查看結果數量
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total' | \
    jq '.data.result | length'

# 如果結果為 0，表示沒有數據
```

### 方法 3: Range Query（時間序列查詢）

```bash
# 獲取時間範圍
START=$(date -d '5 minutes ago' +%s)
END=$(date +%s)

# 查詢過去 5 分鐘的封包計數變化
curl -s -G 'http://localhost:9090/api/v1/query_range' \
    --data-urlencode 'query=rate(jitterbuffer_packet_count_total[5m])' \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode 'step=15s' | jq '.'
```

### 方法 4: 檢查 Prometheus 目標狀態

```bash
# 檢查所有目標
curl -s 'http://localhost:9090/api/v1/targets' | \
    jq '.data.activeTargets[] | {job: .labels.job, health: .health, lastScrape: .lastScrape}'

# 只檢查 ffmpeg-jitterbuffer 目標
curl -s 'http://localhost:9090/api/v1/targets' | \
    jq '.data.activeTargets[] | select(.labels.job == "ffmpeg-jitterbuffer")'
```

## 預期的查詢結果格式

### 當有數據時：

```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "jitterbuffer_packet_count_total",
          "pid": "12345",
          "function": "jitterbuffer_put"
        },
        "value": [1234567890, "1000"]
      }
    ]
  }
}
```

### 當沒有數據時（當前狀態）：

```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": []
  }
}
```

## 常見問題

### 問題 1: 查詢返回空結果

**原因：**
- Exporter 沒有產生數據（probes 沒有成功附加）
- Prometheus 還沒有抓取數據
- Metrics 還沒有被收集

**解決方法：**
1. 檢查 Exporter 是否正在運行
2. 檢查是否有數據產生：`curl http://localhost:9310/metrics | grep -E '^jitterbuffer[^#]'`
3. 檢查 Prometheus 目標狀態
4. 修正 probes 附加問題

### 問題 2: Prometheus 找不到目標

**檢查方法：**
```bash
# 檢查目標配置
curl -s 'http://localhost:9090/api/v1/targets' | \
    jq '.data.activeTargets[] | select(.labels.job == "ffmpeg-jitterbuffer")'
```

**解決方法：**
1. 確認 `prometheus.yml` 中已配置 `ffmpeg-jitterbuffer` job
2. 重啟 Prometheus 或重新載入配置

### 問題 3: 查詢語法錯誤

**檢查方法：**
```bash
# 查詢會返回錯誤信息
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=invalid_query' | jq '.error'
```

## 實用的查詢範例

### 1. 查詢特定 PID 的 metrics

```bash
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total{pid="12345"}' | jq '.'
```

### 2. 查詢特定函數的 metrics

```bash
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total{function="jitterbuffer_put"}' | jq '.'
```

### 3. 計算封包處理速率

```bash
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=rate(jitterbuffer_packet_count_total[5m])' | jq '.'
```

### 4. 計算平均延遲的 95 百分位數

```bash
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=histogram_quantile(0.95, rate(jitterbuffer_delay_seconds_bucket[5m]))' | jq '.'
```

## 下一步

1. 修正 probes 附加問題（檢查函數名稱）
2. 確認 FFmpeg 正在運行並有推流活動
3. 重新啟動 exporter
4. 再次查詢 metrics

