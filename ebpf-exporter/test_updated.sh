#!/bin/bash
# 測試更新後的 exporter

echo "=========================================="
echo "測試更新後的 FFmpeg 庫函數追蹤"
echo "=========================================="
echo ""

# 檢查 FFmpeg 是否在運行
FFMPEG_PID=$(pgrep -f ffmpeg | head -1)
if [ -z "$FFMPEG_PID" ]; then
    echo "⚠ FFmpeg 沒有運行"
    echo "請先啟動 FFmpeg 進行推流，然後再執行此測試"
    echo ""
    echo "範例 FFmpeg 命令："
    echo "  ffmpeg -re -i input.mp4 -c copy -f rtp rtp://127.0.0.1:5004"
    echo ""
    read -p "是否繼續測試 exporter？（即使 FFmpeg 沒有運行）[y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "✓ 找到 FFmpeg 進程 (PID: $FFMPEG_PID)"
fi
echo ""

# 檢查動態庫是否存在
echo "檢查 FFmpeg 動態庫："
for lib in /usr/lib/x86_64-linux-gnu/libavcodec.so.58 \
           /usr/lib/x86_64-linux-gnu/libavformat.so.58 \
           /usr/lib/x86_64-linux-gnu/libavutil.so.56; do
    if [ -f "$lib" ]; then
        echo "  ✓ $lib"
    else
        echo "  ✗ $lib (不存在)"
    fi
done
echo ""

# 檢查函數是否存在
echo "檢查函數符號："
for func in avcodec_send_packet avcodec_receive_frame av_packet_alloc; do
    if nm -D /usr/lib/x86_64-linux-gnu/libavcodec.so.58 2>/dev/null | grep -q "$func"; then
        echo "  ✓ $func (在 libavcodec.so.58 中找到)"
    else
        echo "  ✗ $func (未找到)"
    fi
done
echo ""

# 提示如何啟動 exporter
echo "=========================================="
echo "啟動 Exporter"
echo "=========================================="
echo ""
echo "請在另一個終端執行以下命令："
echo ""
if [ -n "$FFMPEG_PID" ]; then
    echo "  sudo ./ebpf-exporter/start.sh --pid $FFMPEG_PID --port 9310"
else
    echo "  sudo ./ebpf-exporter/start.sh --binary /usr/bin/ffmpeg --port 9310"
fi
echo ""
echo "然後等待幾秒鐘，讓 probes 附加並收集數據"
echo ""

# 等待用戶確認
read -p "按 Enter 繼續驗證 metrics..." 
echo ""

# 驗證 metrics
echo "=========================================="
echo "驗證 Metrics"
echo "=========================================="
echo ""

# 檢查 exporter 是否運行
if ! curl -s http://localhost:9310/health > /dev/null 2>&1; then
    echo "✗ Exporter 沒有運行"
    echo "請先啟動 exporter"
    exit 1
fi

echo "✓ Exporter 正在運行"
echo ""

# 檢查是否有數據
echo "檢查是否有數據："
METRICS=$(curl -s http://localhost:9310/metrics)
DATA_LINES=$(echo "$METRICS" | grep -E '^avcodec|^av_packet' | grep -v '^#' | wc -l)

if [ "$DATA_LINES" -gt 0 ]; then
    echo "✓ 找到 $DATA_LINES 個包含數據的 metrics"
    echo ""
    echo "範例數據："
    echo "$METRICS" | grep -E '^avcodec|^av_packet' | grep -v '^#' | head -5
else
    echo "⚠ 沒有找到包含數據的 metrics"
    echo ""
    echo "可能的原因："
    echo "1. FFmpeg 沒有運行或沒有推流活動"
    echo "2. Probes 沒有成功附加"
    echo "3. 函數名稱不匹配"
    echo ""
    echo "檢查 probes 是否附加："
    echo "  查看 exporter 啟動日誌中的 'Attached probe to' 訊息"
fi

echo ""
echo "=========================================="
echo "測試完成"
echo "=========================================="

