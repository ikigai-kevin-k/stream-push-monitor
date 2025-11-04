# FFmpeg/SRS 推流端 JitterBuffer 監控實作指南

## 推薦方案：Uprobe + BCC

本指南採用 **Uprobe (User-space Probe) + BCC (BPF Compiler Collection)** 方案，這是最適合監控 FFmpeg/SRS 推流端 jitterbuffer 的解決方案。

### 方案優勢

1. **無需修改源碼**：可以直接追蹤已編譯的 FFmpeg/SRS 程式
2. **效能影響小**：eBPF 在核心空間執行，開銷極低（< 5%）
3. **深入應用層**：可以追蹤使用者空間函數的參數和返回值
4. **技術成熟**：BCC 工具鏈完整，易於開發和維護
5. **靈活度高**：可以動態附加/卸載 probe，無需重啟應用程式

### 架構設計

```
FFmpeg/SRS 應用程式
    ↓ (Uprobe 追蹤函數)
eBPF 程式 (核心空間)
    ↓ (BPF Map 儲存 metrics)
Python Exporter (使用者空間)
    ↓ (HTTP 暴露 metrics)
Prometheus Server
```

---

## 系統需求

### 硬體需求
- Linux 核心 4.9+ (支援 eBPF)
- 建議核心 5.8+ (更好的 eBPF 功能支援)

### 軟體需求
- Python 3.6+
- BCC (BPF Compiler Collection)
- libbpf 工具
- FFmpeg/SRS 程式（需要包含 debug symbols 或使用動態符號表）

### 權限需求
- Root 權限或 CAP_BPF, CAP_SYS_ADMIN 權限
- 讀取目標程式記憶體的權限

---

## 詳細執行步驟

### 步驟 1: 安裝 BCC 工具鏈

#### Ubuntu/Debian 系統

```bash
# 更新套件列表
sudo apt-get update

# 安裝 BCC 工具
sudo apt-get install -y bpfcc-tools linux-headers-$(uname -r)

# 安裝 Python BCC 庫
sudo apt-get install -y python3-bpfcc

# 驗證安裝
python3 -c "from bcc import BPF; print('BCC installed successfully')"
```

#### CentOS/RHEL 系統

```bash
# 安裝 EPEL repository
sudo yum install -y epel-release

# 安裝 BCC
sudo yum install -y bcc-tools bcc-devel

# 安裝 Python BCC
sudo yum install -y python3-bcc

# 驗證安裝
python3 -c "from bcc import BPF; print('BCC installed successfully')"
```

#### Docker 容器中安裝

```dockerfile
FROM ubuntu:20.04

# 安裝必要套件
RUN apt-get update && \
    apt-get install -y \
    python3 \
    python3-pip \
    bpfcc-tools \
    linux-headers-$(uname -r) \
    && rm -rf /var/lib/apt/lists/*

# 安裝 Python 依賴
RUN pip3 install bcc prometheus_client

# 設定容器為特權模式
# docker run --privileged ...
```

### 步驟 2: 識別目標函數

在追蹤之前，需要先識別 FFmpeg/SRS 中與 jitterbuffer 相關的關鍵函數。

#### 2.1 使用 objdump 查看符號表

```bash
# 查看 FFmpeg 的符號表
objdump -T /usr/bin/ffmpeg | grep -i jitter

# 查看 SRS 的符號表
objdump -T /usr/local/srs/objs/srs | grep -i jitter
```

#### 2.2 使用 nm 查看符號

```bash
# 查看所有符號
nm -D /usr/bin/ffmpeg | grep -i jitter
nm -D /usr/local/srs/objs/srs | grep -i jitter
```

#### 2.3 使用 readelf 查看動態符號

```bash
# 查看動態符號表
readelf -Ws /usr/bin/ffmpeg | grep -i jitter
```

#### 2.4 常見的 FFmpeg/SRS JitterBuffer 函數名稱

**FFmpeg 相關函數：**
- `ff_rtp_parse_packet` - RTP 封包解析
- `ff_rtp_parse_open` - RTP 解析器開啟
- `ff_rtp_parse_close` - RTP 解析器關閉
- `rtp_parse_packet` - RTP 封包解析
- `av_jitterbuffer_*` - Jitter buffer 相關函數

**SRS 相關函數：**
- `SrsRtpJitterBuffer::put` - 放入封包到 jitter buffer
- `SrsRtpJitterBuffer::get` - 從 jitter buffer 取得封包
- `SrsRtpJitterBuffer::get_time` - 取得 jitter buffer 時間
- `SrsRtpPacket::decode` - RTP 封包解碼

#### 2.5 使用 strace 追蹤系統呼叫

```bash
# 追蹤 FFmpeg 的系統呼叫，找出推流相關函數
strace -p $(pgrep -f ffmpeg) -e trace=write,sendmsg 2>&1 | grep -i rtp
```

### 步驟 3: 編寫 eBPF 程式

創建 eBPF 程式來追蹤 jitterbuffer 相關函數。

#### 3.1 創建 eBPF 程式檔案

創建 `ebpf-exporter/ffmpeg_jitterbuffer_monitor.c`：

```c
#include <uapi/linux/ptrace.h>
#include <linux/sched.h>
#include <bcc/proto.h>

// JitterBuffer metrics structure
struct jitterbuffer_key {
    u32 pid;
    u32 tid;
    char function_name[64];
};

struct jitterbuffer_metrics {
    u64 packet_count;
    u64 total_delay_ns;
    u64 min_delay_ns;
    u64 max_delay_ns;
    u64 buffer_size;
    u64 dropped_packets;
    u64 total_bytes;
    u64 last_timestamp_ns;
};

// BPF maps for storing metrics
BPF_HASH(jitterbuffer_stats, struct jitterbuffer_key, struct jitterbuffer_metrics);
BPF_PERF_OUTPUT(jitterbuffer_events);

// Helper function to get current timestamp
static inline u64 get_timestamp() {
    return bpf_ktime_get_ns();
}

// Probe function entry - 追蹤函數進入
static int probe_jitterbuffer_entry(struct pt_regs *ctx, const char *func_name) {
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), func_name);
    
    struct jitterbuffer_metrics *metrics = jitterbuffer_stats.lookup(&key);
    if (!metrics) {
        struct jitterbuffer_metrics zero = {};
        zero.min_delay_ns = U64_MAX;
        metrics = jitterbuffer_stats.lookup_or_try_init(&key, &zero);
        if (!metrics) {
            return 0;
        }
    }
    
    metrics->last_timestamp_ns = get_timestamp();
    
    return 0;
}

// Probe function return - 追蹤函數返回
static int probe_jitterbuffer_return(struct pt_regs *ctx, const char *func_name) {
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), func_name);
    
    struct jitterbuffer_metrics *metrics = jitterbuffer_stats.lookup(&key);
    if (!metrics) {
        return 0;
    }
    
    u64 current_time = get_timestamp();
    u64 delay = current_time - metrics->last_timestamp_ns;
    
    if (delay > 0) {
        metrics->total_delay_ns += delay;
        if (delay < metrics->min_delay_ns) {
            metrics->min_delay_ns = delay;
        }
        if (delay > metrics->max_delay_ns) {
            metrics->max_delay_ns = delay;
        }
    }
    
    return 0;
}

// Uprobe for jitterbuffer put operation
int jitterbuffer_put_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "jitterbuffer_put");
}

int jitterbuffer_put_return(struct pt_regs *ctx) {
    struct jitterbuffer_metrics *metrics;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), "jitterbuffer_put");
    
    metrics = jitterbuffer_stats.lookup(&key);
    if (metrics) {
        metrics->packet_count++;
        // 嘗試讀取第一個參數（封包大小）
        // 注意：這需要根據實際函數簽名調整
        u64 packet_size = 0;
        if (PT_REGS_PARM1(ctx) != 0) {
            bpf_probe_read_user(&packet_size, sizeof(packet_size), (void *)PT_REGS_PARM1(ctx));
        }
        metrics->total_bytes += packet_size;
    }
    
    return probe_jitterbuffer_return(ctx, "jitterbuffer_put");
}

// Uprobe for jitterbuffer get operation
int jitterbuffer_get_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "jitterbuffer_get");
}

int jitterbuffer_get_return(struct pt_regs *ctx) {
    struct jitterbuffer_metrics *metrics;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), "jitterbuffer_get");
    
    metrics = jitterbuffer_stats.lookup(&key);
    if (metrics) {
        // 檢查返回值（通常為 0 表示成功，負數表示錯誤）
        long ret = PT_REGS_RC(ctx);
        if (ret < 0) {
            metrics->dropped_packets++;
        }
    }
    
    return probe_jitterbuffer_return(ctx, "jitterbuffer_get");
}

// Uprobe for RTP packet parsing
int rtp_parse_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "rtp_parse_packet");
}

int rtp_parse_return(struct pt_regs *ctx) {
    struct jitterbuffer_metrics *metrics;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), "rtp_parse_packet");
    
    metrics = jitterbuffer_stats.lookup(&key);
    if (metrics) {
        metrics->packet_count++;
        // 讀取封包大小（假設是第二個參數）
        u32 packet_size = 0;
        if (PT_REGS_PARM2(ctx) != 0) {
            bpf_probe_read_user(&packet_size, sizeof(packet_size), (void *)PT_REGS_PARM2(ctx));
        }
        metrics->total_bytes += packet_size;
    }
    
    return probe_jitterbuffer_return(ctx, "rtp_parse_packet");
}
```

### 步驟 4: 創建 Python Exporter

創建 `ebpf-exporter/ffmpeg_jitterbuffer_exporter.py`：

```python
#!/usr/bin/env python3
"""
FFmpeg/SRS JitterBuffer Monitor using eBPF
Monitors jitterbuffer metrics and exports to Prometheus
"""

import os
import sys
import time
import json
import signal
from http.server import HTTPServer, BaseHTTPRequestHandler
from prometheus_client import Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST
from bcc import BPF
import ctypes as ct

# Prometheus metrics
jitterbuffer_packet_count = Counter(
    'jitterbuffer_packet_count_total',
    'Total number of packets processed by jitterbuffer',
    ['pid', 'function']
)

jitterbuffer_delay_seconds = Histogram(
    'jitterbuffer_delay_seconds',
    'Jitterbuffer processing delay in seconds',
    ['pid', 'function'],
    buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0]
)

jitterbuffer_buffer_size = Gauge(
    'jitterbuffer_buffer_size_packets',
    'Current buffer size in packets',
    ['pid', 'function']
)

jitterbuffer_dropped_packets = Counter(
    'jitterbuffer_dropped_packets_total',
    'Total number of dropped packets',
    ['pid', 'function']
)

jitterbuffer_bytes_total = Counter(
    'jitterbuffer_bytes_total',
    'Total bytes processed by jitterbuffer',
    ['pid', 'function']
)

jitterbuffer_delay_min = Gauge(
    'jitterbuffer_delay_min_seconds',
    'Minimum delay in seconds',
    ['pid', 'function']
)

jitterbuffer_delay_max = Gauge(
    'jitterbuffer_delay_max_seconds',
    'Maximum delay in seconds',
    ['pid', 'function']
)

jitterbuffer_delay_avg = Gauge(
    'jitterbuffer_delay_avg_seconds',
    'Average delay in seconds',
    ['pid', 'function']
)

class MetricsHandler(BaseHTTPRequestHandler):
    """HTTP handler for Prometheus metrics endpoint"""
    
    def do_GET(self):
        if self.path == '/metrics':
            self.send_response(200)
            self.send_header('Content-Type', CONTENT_TYPE_LATEST)
            self.end_headers()
            self.wfile.write(generate_latest())
        elif self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'healthy'}).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        pass

class JitterBufferExporter:
    """Main JitterBuffer Exporter class"""
    
    def __init__(self, target_binary=None, target_pid=None):
        self.bpf = None
        self.running = True
        self.target_binary = target_binary
        self.target_pid = target_pid
        self.prev_stats = {}
        
        # 設定 signal handler
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        print(f"\nReceived signal {signum}, shutting down...")
        self.running = False
    
    def load_ebpf_program(self):
        """Load eBPF program"""
        try:
            # 讀取 eBPF 程式碼
            ebpf_code_path = os.path.join(
                os.path.dirname(__file__),
                'ffmpeg_jitterbuffer_monitor.c'
            )
            
            if not os.path.exists(ebpf_code_path):
                print(f"Error: eBPF program not found at {ebpf_code_path}")
                return False
            
            with open(ebpf_code_path, 'r') as f:
                bpf_text = f.read()
            
            # 載入 eBPF 程式
            self.bpf = BPF(text=bpf_text)
            
            # 附加 uprobe
            if self.target_binary:
                self.attach_uprobes(self.target_binary)
            elif self.target_pid:
                # 從 PID 獲取二進制檔案路徑
                binary_path = self.get_binary_path(self.target_pid)
                if binary_path:
                    self.attach_uprobes(binary_path)
                else:
                    print(f"Error: Could not find binary for PID {self.target_pid}")
                    return False
            else:
                print("Error: Either target_binary or target_pid must be specified")
                return False
            
            print("eBPF program loaded successfully")
            return True
            
        except Exception as e:
            print(f"Error loading eBPF program: {e}")
            import traceback
            traceback.print_exc()
            return False
    
    def get_binary_path(self, pid):
        """Get binary path from PID"""
        try:
            exe_path = f"/proc/{pid}/exe"
            if os.path.exists(exe_path):
                return os.readlink(exe_path)
        except Exception as e:
            print(f"Error getting binary path: {e}")
        return None
    
    def attach_uprobes(self, binary_path):
        """Attach uprobes to target binary"""
        try:
            # 嘗試附加到常見的函數名稱
            function_names = [
                'jitterbuffer_put',
                'jitterbuffer_get',
                'rtp_parse_packet',
                'ff_rtp_parse_packet',
                'SrsRtpJitterBuffer::put',
                'SrsRtpJitterBuffer::get',
            ]
            
            attached_functions = []
            
            for func_name in function_names:
                try:
                    # 嘗試附加 entry probe
                    self.bpf.attach_uprobe(
                        name=binary_path,
                        sym=func_name,
                        fn_name=f"{func_name.replace('::', '_')}_entry"
                    )
                    
                    # 嘗試附加 return probe
                    self.bpf.attach_uretprobe(
                        name=binary_path,
                        sym=func_name,
                        fn_name=f"{func_name.replace('::', '_')}_return"
                    )
                    
                    attached_functions.append(func_name)
                    print(f"Attached probe to {func_name}")
                    
                except Exception as e:
                    # 函數可能不存在，繼續嘗試下一個
                    continue
            
            if not attached_functions:
                print(f"Warning: Could not attach any probes to {binary_path}")
                print("Please verify function names using: objdump -T <binary> | grep jitter")
                return False
            
            return True
            
        except Exception as e:
            print(f"Error attaching uprobes: {e}")
            import traceback
            traceback.print_exc()
            return False
    
    def collect_metrics(self):
        """Collect metrics from BPF map"""
        try:
            # 讀取 jitterbuffer_stats map
            stats_map = self.bpf["jitterbuffer_stats"]
            
            current_time = time.time()
            
            for key, metrics in stats_map.items():
                pid = key.pid
                func_name = key.function_name.decode('utf-8', errors='ignore')
                
                # 計算平均延遲
                avg_delay = 0.0
                if metrics.packet_count > 0:
                    avg_delay = (metrics.total_delay_ns / metrics.packet_count) / 1e9
                
                # 更新 Prometheus metrics
                jitterbuffer_packet_count.labels(
                    pid=str(pid),
                    function=func_name
                )._value._value = metrics.packet_count
                
                jitterbuffer_dropped_packets.labels(
                    pid=str(pid),
                    function=func_name
                )._value._value = metrics.dropped_packets
                
                jitterbuffer_bytes_total.labels(
                    pid=str(pid),
                    function=func_name
                )._value._value = metrics.total_bytes
                
                if metrics.min_delay_ns != 0xFFFFFFFFFFFFFFFF:
                    jitterbuffer_delay_min.labels(
                        pid=str(pid),
                        function=func_name
                    ).set(metrics.min_delay_ns / 1e9)
                
                if metrics.max_delay_ns > 0:
                    jitterbuffer_delay_max.labels(
                        pid=str(pid),
                        function=func_name
                    ).set(metrics.max_delay_ns / 1e9)
                
                if avg_delay > 0:
                    jitterbuffer_delay_avg.labels(
                        pid=str(pid),
                        function=func_name
                    ).set(avg_delay)
                
                # 記錄 histogram（使用平均延遲作為樣本）
                if avg_delay > 0:
                    jitterbuffer_delay_seconds.labels(
                        pid=str(pid),
                        function=func_name
                    ).observe(avg_delay)
                
                # 更新 buffer size（這裡需要根據實際情況調整）
                # 暫時使用 packet_count 作為近似值
                jitterbuffer_buffer_size.labels(
                    pid=str(pid),
                    function=func_name
                ).set(metrics.packet_count)
                
        except Exception as e:
            print(f"Error collecting metrics: {e}")
            import traceback
            traceback.print_exc()
    
    def run_metrics_collector(self):
        """Run metrics collection loop"""
        while self.running:
            try:
                self.collect_metrics()
                time.sleep(5)  # 每 5 秒收集一次
            except KeyboardInterrupt:
                self.running = False
                break
            except Exception as e:
                print(f"Error in metrics collection: {e}")
                time.sleep(5)
    
    def run(self, port=9310):
        """Run the exporter"""
        # 載入 eBPF 程式
        if not self.load_ebpf_program():
            print("Failed to load eBPF program")
            return
        
        # 啟動 metrics 收集執行緒
        import threading
        collector_thread = threading.Thread(target=self.run_metrics_collector, daemon=True)
        collector_thread.start()
        
        # 啟動 HTTP server
        server = HTTPServer(('0.0.0.0', port), MetricsHandler)
        print(f"JitterBuffer Exporter running on port {port}")
        print(f"Metrics endpoint: http://0.0.0.0:{port}/metrics")
        print(f"Health endpoint: http://0.0.0.0:{port}/health")
        
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down...")
            self.running = False
            server.shutdown()

def main():
    """Main entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(description='FFmpeg/SRS JitterBuffer Monitor')
    parser.add_argument(
        '--binary',
        type=str,
        help='Path to target binary (e.g., /usr/bin/ffmpeg)'
    )
    parser.add_argument(
        '--pid',
        type=int,
        help='PID of target process'
    )
    parser.add_argument(
        '--port',
        type=int,
        default=9310,
        help='Port for metrics endpoint (default: 9310)'
    )
    
    args = parser.parse_args()
    
    if not args.binary and not args.pid:
        parser.error("Either --binary or --pid must be specified")
    
    exporter = JitterBufferExporter(
        target_binary=args.binary,
        target_pid=args.pid
    )
    
    exporter.run(port=args.port)

if __name__ == '__main__':
    main()
```

### 步驟 5: 設定權限和執行

#### 5.1 設定檔案權限

```bash
# 設定執行權限
chmod +x ebpf-exporter/ffmpeg_jitterbuffer_exporter.py

# 確保 Python 可以執行
python3 -m pip install bcc prometheus_client
```

#### 5.2 執行 Exporter

**方式 1: 指定二進制檔案路徑**

```bash
sudo python3 ebpf-exporter/ffmpeg_jitterbuffer_exporter.py \
    --binary /usr/bin/ffmpeg \
    --port 9310
```

**方式 2: 指定 PID**

```bash
# 先找到 FFmpeg 的 PID
FFMPEG_PID=$(pgrep -f ffmpeg | head -1)

# 執行 exporter
sudo python3 ebpf-exporter/ffmpeg_jitterbuffer_exporter.py \
    --pid $FFMPEG_PID \
    --port 9310
```

#### 5.3 驗證執行

```bash
# 檢查 metrics endpoint
curl http://localhost:9310/metrics | grep jitterbuffer

# 檢查健康狀態
curl http://localhost:9310/health
```

### 步驟 6: 配置 Prometheus

#### 6.1 更新 prometheus.yml

在 `prometheus.yml` 中添加新的 job：

```yaml
scrape_configs:
  # ... 其他配置 ...
  
  - job_name: 'ffmpeg-jitterbuffer'
    static_configs:
      - targets: ['localhost:9310']
    metrics_path: '/metrics'
    scrape_interval: 10s
    scrape_timeout: 5s
```

#### 6.2 重啟 Prometheus

```bash
# 如果使用 Docker Compose
docker compose restart prometheus

# 或重新載入配置（如果支援）
curl -X POST http://localhost:9090/-/reload
```

### 步驟 7: 驗證 Metrics

#### 7.1 檢查 Prometheus 目標

訪問 http://localhost:9090/targets，確認 `ffmpeg-jitterbuffer` job 狀態為 "UP"。

#### 7.2 查詢 Metrics

在 Prometheus 中查詢以下 metrics：

```promql
# 封包計數
jitterbuffer_packet_count_total

# 延遲統計
jitterbuffer_delay_avg_seconds
jitterbuffer_delay_min_seconds
jitterbuffer_delay_max_seconds

# 丟棄的封包
jitterbuffer_dropped_packets_total

# 處理的位元組數
jitterbuffer_bytes_total

# Buffer 大小
jitterbuffer_buffer_size_packets
```

#### 7.3 建立 Grafana Dashboard

創建 Grafana dashboard 來視覺化這些 metrics：

```json
{
  "dashboard": {
    "title": "FFmpeg/SRS JitterBuffer Monitoring",
    "panels": [
      {
        "title": "Packet Count",
        "targets": [
          {
            "expr": "rate(jitterbuffer_packet_count_total[5m])",
            "legendFormat": "{{function}}"
          }
        ]
      },
      {
        "title": "Average Delay",
        "targets": [
          {
            "expr": "jitterbuffer_delay_avg_seconds",
            "legendFormat": "{{function}}"
          }
        ]
      },
      {
        "title": "Dropped Packets",
        "targets": [
          {
            "expr": "rate(jitterbuffer_dropped_packets_total[5m])",
            "legendFormat": "{{function}}"
          }
        ]
      }
    ]
  }
}
```

---

## 故障排除

### 問題 1: 無法附加 Uprobe

**症狀：**
```
Error attaching uprobes: Failed to attach uprobe
```

**解決方案：**
1. 確認目標二進制檔案存在且有執行權限
2. 確認函數名稱正確（使用 `objdump -T` 驗證）
3. 確認有 root 權限
4. 檢查核心版本是否支援 eBPF

### 問題 2: 沒有 Metrics 資料

**症狀：**
Metrics endpoint 返回空或沒有資料

**解決方案：**
1. 確認目標程式正在運行
2. 確認函數名稱正確
3. 檢查 eBPF 程式是否成功載入：`dmesg | tail -20`
4. 使用 `bpftool` 檢查 BPF map：
   ```bash
   bpftool map show
   ```

### 問題 3: 權限錯誤

**症狀：**
```
Permission denied
```

**解決方案：**
1. 使用 `sudo` 執行
2. 或設定 capabilities：
   ```bash
   sudo setcap cap_sys_admin,cap_bpf+eip /usr/bin/python3
   ```

### 問題 4: 函數名稱不匹配

**症狀：**
```
Warning: Could not attach any probes
```

**解決方案：**
1. 使用 `objdump -T` 或 `nm -D` 查看實際函數名稱
2. 如果函數被 C++ 名稱修飾（mangling），需要提供完整名稱
3. 可以使用 `c++filt` 解碼函數名稱：
   ```bash
   echo "_ZN3Srs14RtpJitterBuffer3putEPNS_10RtpPacketE" | c++filt
   ```

### 問題 5: 效能影響過大

**症狀：**
目標程式效能下降明顯

**解決方案：**
1. 減少 probe 的數量
2. 增加收集間隔時間
3. 只在關鍵函數上附加 probe
4. 考慮使用 fprobe 替代 uprobe（核心 5.15+）

---

## 進階優化

### 1. 使用 Fprobe（核心 5.15+）

Fprobe 比 Uprobe 更輕量，適合高頻函數：

```c
// 使用 fprobe 替代 uprobe
SEC("fprobe/function_name")
int BPF_PROG(jitterbuffer_probe, struct pt_regs *regs) {
    // 處理邏輯
}
```

### 2. 使用 Ring Buffer（核心 5.8+）

使用 Ring Buffer 替代 Perf Buffer，減少開銷：

```c
BPF_RINGBUF_OUTPUT(jitterbuffer_events, 4096);
```

### 3. 過濾特定 PID

只追蹤特定 PID 的呼叫：

```c
u64 target_pid = 12345;
u64 current_pid = bpf_get_current_pid_tgid() >> 32;
if (current_pid != target_pid) {
    return 0;
}
```

### 4. 使用 USDT（如果可用）

如果目標程式支援 USDT，效能會更好：

```c
// 在目標程式中添加
DTRACE_PROBE2(ffmpeg, jitterbuffer, packet_count, delay);

// 在 eBPF 中追蹤
USDT_PROBE(ffmpeg, jitterbuffer);
```

---

## 參考資源

- [BCC 文件](https://github.com/iovisor/bcc)
- [eBPF 官方文件](https://ebpf.io/)
- [BPF 和 XDP 參考指南](https://docs.cilium.io/en/stable/bpf/)
- [FFmpeg 源碼](https://github.com/FFmpeg/FFmpeg)
- [SRS 源碼](https://github.com/ossrs/srs)

---

## 總結

本指南提供了使用 eBPF Uprobe 監控 FFmpeg/SRS 推流端 jitterbuffer 的完整解決方案。主要優勢包括：

1. **無需修改源碼**：直接追蹤已編譯的程式
2. **效能影響小**：eBPF 在核心空間執行，開銷極低
3. **深入應用層**：可以追蹤函數參數和返回值
4. **靈活度高**：可以動態附加/卸載 probe

透過遵循本指南的步驟，您可以成功監控推流端的 jitterbuffer 指標，並將其導出到 Prometheus 進行分析和告警。

