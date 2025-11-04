# 快速查詢指南

## 當前狀態

從您的終端輸出可以看到：
- ✅ Exporter 正常運行（健康檢查通過）
- ✅ Metrics 定義已註冊
- ⚠️ 沒有實際數據值（因為沒有成功附加 probes）

## PromQL API 查詢範例

### 方法 1: 直接查詢 Exporter（推薦，無需 Prometheus）

```bash
# 查詢所有 jitterbuffer metrics（包含實際值的行）
curl -s http://localhost:9310/metrics | grep -E '^jitterbuffer[^#]'

# 查詢特定 metric 的實際值
curl -s http://localhost:9310/metrics | grep -E '^jitterbuffer_packet_count_total[^#]'

# 使用 jq 格式化（如果安裝了 jq）
curl -s http://localhost:9310/metrics | grep -E '^jitterbuffer[^#]' | \
    awk '{print $1 "=" $2}'
```

### 方法 2: 使用 PromQL API（需要 Prometheus 運行）

#### 基本查詢

```bash
# 查詢所有 jitterbuffer metrics
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query={__name__=~"jitterbuffer.*"}'

# 使用 jq 格式化輸出
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query={__name__=~"jitterbuffer.*"}' | \
    jq '.data.result[] | {metric: .metric.__name__, value: .value[1], timestamp: .value[0]}'
```

#### 查詢特定 Metrics

```bash
# 封包計數
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total' | jq '.'

# 平均延遲
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_delay_avg_seconds' | jq '.'

# 查詢特定 PID 的 metrics
curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total{pid="12345"}' | jq '.'
```

#### Range Query（時間序列查詢）

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

#### 檢查 Prometheus 目標狀態

```bash
# 檢查所有目標
curl -s 'http://localhost:9090/api/v1/targets' | \
    jq '.data.activeTargets[] | {job: .labels.job, health: .health, lastScrape: .lastScrape}'

# 檢查 ffmpeg-jitterbuffer 目標
curl -s 'http://localhost:9090/api/v1/targets' | \
    jq '.data.activeTargets[] | select(.labels.job == "ffmpeg-jitterbuffer")'
```

## 為什麼沒有數據？

從之前的輸出可以看到：
```
Warning: Could not attach any probes to /usr/bin/ffmpeg
```

這表示：
1. ⚠️ Uprobe 沒有成功附加到 FFmpeg 的函數
2. ⚠️ 因此沒有收集到任何數據

### 解決方法

1. **檢查 FFmpeg 中實際的函數名稱**：
```bash
# 查看所有符號
objdump -T /usr/bin/ffmpeg | grep -i jitter

# 或使用 nm
nm -D /usr/bin/ffmpeg | grep -i jitter

# 或使用 readelf
readelf -Ws /usr/bin/ffmpeg | grep -i jitter
```

2. **修正函數名稱**：
   - 編輯 `ffmpeg_jitterbuffer_exporter.py` 中的 `function_names` 列表
   - 根據實際找到的函數名稱更新

3. **確認 FFmpeg 正在運行**：
```bash
# 檢查 FFmpeg 進程
ps aux | grep ffmpeg

# 如果有運行，使用 PID 方式啟動
sudo ./ebpf-exporter/start.sh --pid $(pgrep -f ffmpeg | head -1) --port 9310
```

## 測試腳本

使用提供的測試腳本：

```bash
# 測試 PromQL API
./ebpf-exporter/test_promql.sh

# 驗證 Metrics
./ebpf-exporter/verify_metrics.sh
```

## 預期的輸出格式

### 當有數據時，Exporter 會返回：

```prometheus
# HELP jitterbuffer_packet_count_total Total number of packets processed by jitterbuffer
# TYPE jitterbuffer_packet_count_total counter
jitterbuffer_packet_count_total{pid="12345",function="jitterbuffer_put"} 1000.0
```

### 當沒有數據時（當前狀態）：

```prometheus
# HELP jitterbuffer_packet_count_total Total number of packets processed by jitterbuffer
# TYPE jitterbuffer_packet_count_total counter
# (沒有實際數據行)
```

## 下一步

1. 先確認 FFmpeg 的實際函數名稱
2. 更新 exporter 中的函數名稱列表
3. 重新啟動 exporter
4. 再次查詢 metrics

