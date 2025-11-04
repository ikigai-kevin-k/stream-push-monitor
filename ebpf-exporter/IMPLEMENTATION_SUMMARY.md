# 實施總結

## 已完成的更新

### 方案 1: 追蹤 FFmpeg 庫函數 ✅

#### 1. 更新 Exporter (`ffmpeg_jitterbuffer_exporter.py`)

**更新內容：**
- 添加了 FFmpeg 庫函數列表：
  - `avcodec_send_packet` - 發送封包到解碼器
  - `avcodec_receive_frame` - 從解碼器接收幀
  - `av_packet_alloc` - 分配封包
  - `av_packet_ref` - 引用封包
  - `av_packet_unref` - 釋放封包
  - `av_bsf_send_packet` - 發送封包到 bitstream filter
  - `av_bsf_receive_packet` - 從 bitstream filter 接收封包

- 更新 `attach_uprobes` 方法：
  - 支援在動態庫中附加 probes（`libavcodec.so.58`, `libavformat.so.58`, `libavutil.so.56`）
  - 同時嘗試在主二進制檔案和動態庫中附加
  - 改進錯誤處理和日誌輸出

#### 2. 更新 eBPF 程式 (`ffmpeg_jitterbuffer_monitor.c`)

**更新內容：**
- 為每個 FFmpeg 庫函數添加了專用的 entry/return 處理函數：
  - `avcodec_send_packet_entry/return`
  - `avcodec_receive_frame_entry/return`
  - `av_packet_alloc_entry/return`
  - `av_packet_ref_entry/return`
  - `av_packet_unref_entry/return`
  - `av_bsf_send_packet_entry/return`
  - `av_bsf_receive_packet_entry/return`

- 每個函數都實現了適當的 metrics 收集邏輯：
  - 封包計數
  - 延遲統計
  - 錯誤檢測（返回值 < 0）

## 實施步驟

### 步驟 1: 更新代碼 ✅

已完成：
- [x] 更新 exporter 函數列表
- [x] 更新 attach_uprobes 方法以支援動態庫
- [x] 更新 eBPF 程式以處理 FFmpeg 庫函數

### 步驟 2: 測試更新後的 exporter

執行測試腳本：

```bash
./ebpf-exporter/test_updated.sh
```

或手動測試：

```bash
# 1. 啟動 FFmpeg（如果還沒有運行）
ffmpeg -re -i input.mp4 -c copy -f rtp rtp://127.0.0.1:5004

# 2. 在另一個終端啟動 exporter
sudo ./ebpf-exporter/start.sh --binary /usr/bin/ffmpeg --port 9310

# 3. 驗證 metrics
curl http://localhost:9310/metrics | grep -E '^avcodec|^av_packet'
```

### 步驟 3: 驗證數據收集

檢查以下指標：

1. **Probes 是否成功附加**
   - 查看 exporter 啟動日誌中的 "Attached probe to" 訊息

2. **是否有數據產生**
   ```bash
   curl http://localhost:9310/metrics | grep -E '^avcodec|^av_packet' | grep -v '^#'
   ```

3. **Prometheus 查詢**
   ```bash
   curl -G 'http://localhost:9090/api/v1/query' \
       --data-urlencode 'query=avcodec_send_packet_count_total'
   ```

## 下一步計劃

### 方案 2: 網路層追蹤（待實施）

如果方案 1 無法提供足夠的 jitter buffer 信息，可以實施方案 2：

**計劃：**
- 追蹤系統調用（send/recv/sendto/recvfrom）
- 解析 RTP/UDP 封包
- 計算網路層面的延遲和 jitter

**優點：**
- 不需要知道應用層函數名稱
- 可以追蹤所有網路流量
- 適用於任何應用程式

**缺點：**
- 無法直接獲取 jitter buffer 內部狀態
- 需要解析 RTP/UDP 封包

## 故障排除

### 問題 1: Probes 沒有成功附加

**檢查方法：**
```bash
# 檢查函數是否存在
nm -D /usr/lib/x86_64-linux-gnu/libavcodec.so.58 | grep avcodec_send_packet

# 檢查庫文件是否存在
ls -l /usr/lib/x86_64-linux-gnu/libavcodec.so.58
```

**解決方法：**
- 確認庫文件路徑正確（可能需要調整版本號）
- 確認有足夠的權限（需要 root 或 CAP_BPF）

### 問題 2: 沒有數據產生

**可能原因：**
- FFmpeg 沒有運行或沒有推流活動
- 函數沒有被調用（需要實際的推流操作）

**解決方法：**
- 確認 FFmpeg 正在運行並有推流活動
- 檢查 FFmpeg 日誌確認函數被調用

### 問題 3: 函數名稱不匹配

**檢查方法：**
```bash
# 查看實際的函數符號
nm -D /usr/lib/x86_64-linux-gnu/libavcodec.so.58 | grep -E "avcodec|av_packet"
```

**解決方法：**
- 根據實際符號更新函數名稱列表
- 注意函數可能有版本後綴（如 `@@LIBAVCODEC_58`）

## 測試結果

執行測試後，應該能看到：

1. **Probes 成功附加**
   ```
   Attached probe to avcodec_send_packet in /usr/lib/x86_64-linux-gnu/libavcodec.so.58
   Attached probe to avcodec_receive_frame in /usr/lib/x86_64-linux-gnu/libavcodec.so.58
   ```

2. **Metrics 有數據**
   ```
   avcodec_send_packet_packet_count_total{pid="12345",function="avcodec_send_packet"} 100.0
   avcodec_send_packet_delay_avg_seconds{pid="12345",function="avcodec_send_packet"} 0.001
   ```

## 總結

方案 1 已經實施完成。現在 exporter 可以：

1. ✅ 追蹤 FFmpeg 庫函數（在動態庫中）
2. ✅ 收集封包處理 metrics
3. ✅ 計算延遲統計
4. ✅ 檢測錯誤（返回值 < 0）

下一步是測試並根據實際情況調整。

