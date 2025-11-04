# FFmpeg/SRS JitterBuffer Monitor

使用 eBPF Uprobe 監控 FFmpeg/SRS 推流端 JitterBuffer 的最小可行方案。

## 系統需求

- Linux 核心 4.9+ (建議 5.8+)
- Python 3.6+
- BCC (BPF Compiler Collection)
- Root 權限或 CAP_BPF, CAP_SYS_ADMIN 權限

## 安裝步驟

### 1. 安裝 BCC 工具鏈

#### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install -y bpfcc-tools linux-headers-$(uname -r)
sudo apt-get install -y python3-bpfcc
```

#### CentOS/RHEL
```bash
sudo yum install -y epel-release
sudo yum install -y bcc-tools bcc-devel
sudo yum install -y python3-bcc
```

### 2. 安裝 Python 依賴

**重要**: 
- BCC 必須通過系統套件管理器安裝，不能通過 pip 安裝
- 因為需要 sudo 執行監控腳本，所以 `prometheus_client` 必須安裝到系統 Python，而不是虛擬環境

```bash
# 在系統層級安裝 prometheus_client（不使用虛擬環境）
pip3 install prometheus_client

# 或者使用 --user 安裝到用戶目錄
pip3 install --user prometheus_client
```

**注意**: 
- `requirements.txt` 中不包含 `bcc`，因為它必須通過系統套件管理器安裝
- 如果您在虛擬環境中安裝了 `prometheus_client`，sudo 執行腳本時仍然會找不到，必須在系統層級安裝

### 3. 設定執行權限

```bash
chmod +x ffmpeg_jitterbuffer_exporter.py
```

## 使用方法

### 方式 1: 指定二進制檔案路徑

```bash
sudo python3 ffmpeg_jitterbuffer_exporter.py \
    --binary /usr/bin/ffmpeg \
    --port 9310
```

### 方式 2: 指定 PID

```bash
# 先找到 FFmpeg 的 PID
FFMPEG_PID=$(pgrep -f ffmpeg | head -1)

# 執行 exporter
sudo python3 ffmpeg_jitterbuffer_exporter.py \
    --pid $FFMPEG_PID \
    --port 9310
```

## 驗證

### 檢查 Metrics Endpoint

```bash
curl http://localhost:9310/metrics | grep jitterbuffer
```

### 檢查健康狀態

```bash
curl http://localhost:9310/health
```

## Prometheus 配置

在 `prometheus.yml` 中添加：

```yaml
scrape_configs:
  - job_name: 'ffmpeg-jitterbuffer'
    static_configs:
      - targets: ['localhost:9310']
    metrics_path: '/metrics'
    scrape_interval: 10s
```

## Available Metrics

The following Prometheus metrics are available from the exporter endpoint:

### Counter Metrics

| Metric Name | Type | Description | Labels |
|-------------|------|-------------|--------|
| `jitterbuffer_packet_count_total` | Counter | Total number of packets processed by jitterbuffer | `pid`, `function` |
| `jitterbuffer_dropped_packets_total` | Counter | Total number of dropped packets | `pid`, `function` |
| `jitterbuffer_bytes_total` | Counter | Total bytes processed by jitterbuffer | `pid`, `function` |

### Gauge Metrics

| Metric Name | Type | Description | Labels |
|-------------|------|-------------|--------|
| `jitterbuffer_delay_avg_seconds` | Gauge | Average delay in seconds | `pid`, `function` |
| `jitterbuffer_delay_min_seconds` | Gauge | Minimum delay in seconds | `pid`, `function` |
| `jitterbuffer_delay_max_seconds` | Gauge | Maximum delay in seconds | `pid`, `function` |
| `jitterbuffer_buffer_size_packets` | Gauge | Current buffer size in packets | `pid`, `function` |

### Histogram Metrics

| Metric Name | Type | Description | Labels | Buckets |
|-------------|------|-------------|--------|---------|
| `jitterbuffer_delay_seconds` | Histogram | Jitterbuffer processing delay distribution | `pid`, `function` | 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0 |

### Label Descriptions

- **`pid`**: Process ID of the monitored FFmpeg/SRS process
- **`function`**: Function name being tracked (e.g., `avcodec_send_packet`, `avcodec_receive_frame`, `jitterbuffer_put`, etc.)

### Example PromQL Queries

```promql
# Total packet count
jitterbuffer_packet_count_total

# Packet processing rate (packets per second)
rate(jitterbuffer_packet_count_total[5m])

# Average delay by function
jitterbuffer_delay_avg_seconds{function="avcodec_send_packet"}

# 95th percentile delay
histogram_quantile(0.95, rate(jitterbuffer_delay_seconds_bucket[5m]))

# Dropped packet rate
rate(jitterbuffer_dropped_packets_total[5m])

# Bytes processed per second
rate(jitterbuffer_bytes_total[5m])
```

### Querying Metrics via Prometheus API

```bash
# Query all jitterbuffer metrics
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query={__name__=~"jitterbuffer.*"}'

# Query packet count
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_packet_count_total'

# Query average delay
curl -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=jitterbuffer_delay_avg_seconds'
```

## 故障排除

### 無法附加 Uprobe

1. 確認目標二進制檔案存在且有執行權限
2. 確認函數名稱正確（使用 `objdump -T <binary> | grep jitter` 驗證）
3. 確認有 root 權限
4. 檢查核心版本是否支援 eBPF

### 沒有 Metrics 資料

1. 確認目標程式正在運行
2. 確認函數名稱正確
3. 檢查 eBPF 程式是否成功載入：`dmesg | tail -20`
4. 使用 `bpftool map show` 檢查 BPF map

### 函數名稱不匹配

使用以下命令查看實際函數名稱：

```bash
objdump -T /usr/bin/ffmpeg | grep -i jitter
nm -D /usr/bin/ffmpeg | grep -i jitter
```

如果是 C++ 函數，可能需要使用完整名稱（name mangling）。

## 注意事項

- 此方案需要 root 權限執行
- 函數名稱需要根據實際的 FFmpeg/SRS 版本進行調整
- 某些函數可能需要 debug symbols 才能正確追蹤
- 建議在測試環境中先驗證函數名稱

