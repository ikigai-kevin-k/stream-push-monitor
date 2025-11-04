# 故障排除指南

## 問題：找不到 Jitter Buffer 相關函數

### 診斷結果

執行 `objdump -T /usr/bin/ffmpeg | grep -i jitter` 沒有找到相關函數。

### 原因分析

1. **FFmpeg 的 jitter buffer 可能在內部實現**
   - Jitter buffer 邏輯可能封裝在內部函數中
   - 這些函數可能沒有導出到符號表

2. **函數可能在動態庫中**
   - FFmpeg 使用 libavcodec、libavformat 等庫
   - Jitter buffer 可能在這些庫中實現

3. **函數名稱可能不同**
   - 實際的函數名稱可能不包含 "jitter" 關鍵字
   - 可能使用其他名稱（如 buffer、queue、delay 等）

### 解決方案

#### 方案 1: 追蹤網路層面的操作（推薦）

由於無法直接追蹤 jitter buffer，可以追蹤網路層面的操作：

```c
// 追蹤 socket send/recv
// 使用 kprobe 追蹤 send/recv 系統調用
// 可以獲取封包大小、時間戳等信息
```

**優點：**
- 不需要知道內部函數名稱
- 可以追蹤所有網路流量
- 適用於任何應用程式

**缺點：**
- 無法直接獲取 jitter buffer 的內部狀態
- 需要解析 RTP/UDP 封包

#### 方案 2: 追蹤 FFmpeg 庫函數

追蹤 FFmpeg 的公開 API 函數：

```python
# 在 exporter 中添加以下函數名稱：
function_names = [
    'avcodec_send_packet',      # 發送封包到解碼器
    'avcodec_receive_frame',   # 從解碼器接收幀
    'av_packet_alloc',          # 分配封包
    'av_packet_ref',            # 引用封包
    'av_packet_unref',          # 釋放封包
]
```

**優點：**
- 可以追蹤封包處理流程
- 函數名稱已知且穩定

**缺點：**
- 無法直接獲取 jitter buffer 狀態
- 需要推斷 jitter buffer 的行為

#### 方案 3: 使用 System Call 追蹤

追蹤系統調用層面的操作：

```bash
# 使用 strace 查看 FFmpeg 的系統調用
strace -p $(pgrep -f ffmpeg) -e trace=network

# 或使用 eBPF 追蹤系統調用
# 追蹤 send/recv/sendto/recvfrom 等
```

**優點：**
- 不需要知道應用層函數
- 可以獲取網路流量信息

**缺點：**
- 性能開銷較大
- 無法獲取應用層狀態

#### 方案 4: 修改 FFmpeg 添加 USDT Probes（最完整）

在 FFmpeg 源碼中添加 USDT probes：

```c
// 在 FFmpeg 源碼的 jitter buffer 相關代碼中添加
DTRACE_PROBE2(ffmpeg, jitterbuffer_put, packet_count, delay);
DTRACE_PROBE2(ffmpeg, jitterbuffer_get, packet_count, delay);
```

**優點：**
- 可以獲取精確的 jitter buffer 狀態
- 性能影響最小

**缺點：**
- 需要重新編譯 FFmpeg
- 需要修改源碼

### 建議的實現方案

對於最小可行方案（MVP），建議使用**方案 1 + 方案 2** 的組合：

1. **追蹤網路層操作**（獲取封包信息）
2. **追蹤 FFmpeg 庫函數**（獲取封包處理流程）
3. **計算 jitter buffer 相關指標**（基於封包時間戳和處理時間）

### 使用診斷腳本

執行診斷腳本查找更多信息：

```bash
./ebpf-exporter/find_functions.sh /usr/bin/ffmpeg
```

### 下一步

1. 執行診斷腳本查看所有可追蹤的函數
2. 根據實際情況選擇合適的方案
3. 更新 exporter 以使用找到的函數名稱
4. 如果需要，實現網路層追蹤

