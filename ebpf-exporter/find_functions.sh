#!/bin/bash
# 查找 FFmpeg/SRS 中可追蹤的函數腳本

BINARY_PATH=${1:-/usr/bin/ffmpeg}

echo "=========================================="
echo "查找 FFmpeg/SRS 中可追蹤的函數"
echo "=========================================="
echo ""
echo "目標二進制檔案: $BINARY_PATH"
echo ""

if [ ! -f "$BINARY_PATH" ]; then
    echo "錯誤: 檔案不存在: $BINARY_PATH"
    exit 1
fi

echo "1. 查找 jitter 相關函數："
echo "----------------------------------------"
objdump -T "$BINARY_PATH" 2>/dev/null | grep -i jitter || echo "   (未找到)"
echo ""

echo "2. 查找 RTP 相關函數："
echo "----------------------------------------"
objdump -T "$BINARY_PATH" 2>/dev/null | grep -i rtp | head -10 || echo "   (未找到)"
echo ""

echo "3. 查找 packet 相關函數："
echo "----------------------------------------"
objdump -T "$BINARY_PATH" 2>/dev/null | grep -iE "packet.*put|packet.*get|packet.*parse" | head -10 || echo "   (未找到)"
echo ""

echo "4. 查找所有可導出的函數（使用 nm）："
echo "----------------------------------------"
nm -D "$BINARY_PATH" 2>/dev/null | grep -iE "(rtp|packet|buffer)" | head -20 || echo "   (未找到)"
echo ""

echo "5. 查找動態庫依賴："
echo "----------------------------------------"
ldd "$BINARY_PATH" 2>/dev/null | grep -iE "(av|rtp|codec)" | head -10 || echo "   (未找到)"
echo ""

echo "6. 檢查是否有 debug symbols："
echo "----------------------------------------"
if readelf -S "$BINARY_PATH" 2>/dev/null | grep -q "\.debug"; then
    echo "   ✓ 找到 debug symbols"
else
    echo "   ⚠ 沒有找到 debug symbols"
    echo "   這可能導致無法追蹤內部函數"
fi
echo ""

echo "=========================================="
echo "建議"
echo "=========================================="
echo ""
echo "如果沒有找到 jitter buffer 相關函數，可以考慮："
echo ""
echo "1. 追蹤網路層面的操作（socket send/recv）："
echo "   - 使用 kprobe 追蹤 send/recv 系統調用"
echo "   - 追蹤 RTP/UDP 封包"
echo ""
echo "2. 追蹤 FFmpeg 庫函數："
echo "   - 追蹤 libavcodec 中的 packet 處理函數"
echo "   - 追蹤 avcodec_send_packet/avcodec_receive_frame"
echo ""
echo "3. 使用 USDT（如果 FFmpeg 支援）："
echo "   - 需要 FFmpeg 編譯時啟用 USDT 支援"
echo ""
echo "4. 修改 FFmpeg 源碼添加 USDT probes："
echo "   - 在 jitter buffer 相關代碼中添加 DTRACE_PROBE"
echo ""

