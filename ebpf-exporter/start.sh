#!/bin/bash
# FFmpeg/SRS JitterBuffer Monitor 啟動腳本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORTER_SCRIPT="${SCRIPT_DIR}/ffmpeg_jitterbuffer_exporter.py"

# 檢查是否為 root
if [ "$EUID" -ne 0 ]; then 
    echo "錯誤: 此腳本需要 root 權限執行"
    echo "請使用: sudo $0"
    exit 1
fi

# 檢查 BCC 是否安裝
if ! python3 -c "from bcc import BPF" 2>/dev/null; then
    echo "錯誤: BCC 未安裝或無法導入"
    echo "請先安裝 BCC:"
    echo "  Ubuntu/Debian: sudo apt-get install python3-bpfcc"
    echo "  CentOS/RHEL: sudo yum install python3-bcc"
    exit 1
fi

# 檢查 Python 依賴（prometheus_client）
# 嘗試找到用戶級別的安裝（--user 安裝）
USER_SITE_PACKAGES=""
if [ -n "$SUDO_USER" ]; then
    # 如果使用 sudo，嘗試找到原始用戶的 site-packages
    USER_HOME=$(eval echo ~$SUDO_USER)
    # 找到實際的 Python 版本目錄
    for py_ver_dir in "${USER_HOME}/.local/lib/python3"*; do
        if [ -d "$py_ver_dir/site-packages" ]; then
            USER_SITE_PACKAGES="$py_ver_dir/site-packages"
            break
        fi
    done
elif [ -n "$HOME" ]; then
    # 如果沒有使用 sudo，使用當前用戶
    for py_ver_dir in "$HOME/.local/lib/python3"*; do
        if [ -d "$py_ver_dir/site-packages" ]; then
            USER_SITE_PACKAGES="$py_ver_dir/site-packages"
            break
        fi
    done
fi

# 檢查是否可以使用系統級別的安裝
if python3 -c "import prometheus_client" 2>/dev/null; then
    # 系統級別已安裝，可以繼續
    :
# 檢查用戶級別的安裝
elif [ -n "$USER_SITE_PACKAGES" ] && [ -d "$USER_SITE_PACKAGES" ]; then
    # 找到用戶級別安裝，設置 PYTHONPATH
    export PYTHONPATH="${USER_SITE_PACKAGES}:${PYTHONPATH}"
    # 驗證是否可以導入
    if ! python3 -c "import prometheus_client" 2>/dev/null; then
        echo "錯誤: 無法載入用戶級別的 prometheus_client"
        echo "找到的目錄: $USER_SITE_PACKAGES"
        exit 1
    fi
else
    echo "錯誤: prometheus_client 未安裝"
    echo ""
    echo "請執行以下命令之一："
    echo ""
    echo "1. 安裝到用戶目錄（推薦，不需要 sudo）："
    echo "   pip3 install --user prometheus_client"
    echo ""
    echo "2. 安裝到系統級別（需要 sudo）："
    echo "   sudo pip3 install prometheus_client"
    exit 1
fi

# 預設參數
PORT=9310
BINARY=""
PID=""

# 解析參數
while [[ $# -gt 0 ]]; do
    case $1 in
        --binary)
            BINARY="$2"
            shift 2
            ;;
        --pid)
            PID="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        -h|--help)
            echo "用法: $0 [選項]"
            echo ""
            echo "選項:"
            echo "  --binary PATH    目標二進制檔案路徑 (例如: /usr/bin/ffmpeg)"
            echo "  --pid PID        目標進程 PID"
            echo "  --port PORT      監聽端口 (預設: 9310)"
            echo "  -h, --help       顯示此幫助訊息"
            echo ""
            echo "範例:"
            echo "  $0 --binary /usr/bin/ffmpeg"
            echo "  $0 --pid \$(pgrep -f ffmpeg | head -1)"
            exit 0
            ;;
        *)
            echo "未知參數: $1"
            echo "使用 -h 或 --help 查看幫助"
            exit 1
            ;;
    esac
done

# 檢查是否提供了 binary 或 pid
if [ -z "$BINARY" ] && [ -z "$PID" ]; then
    echo "錯誤: 必須指定 --binary 或 --pid"
    echo "使用 -h 或 --help 查看幫助"
    exit 1
fi

# 構建命令
CMD="python3 ${EXPORTER_SCRIPT}"
if [ -n "$BINARY" ]; then
    CMD="${CMD} --binary ${BINARY}"
fi
if [ -n "$PID" ]; then
    CMD="${CMD} --pid ${PID}"
fi
CMD="${CMD} --port ${PORT}"

echo "啟動 JitterBuffer Monitor..."
echo "命令: ${CMD}"
echo ""

# 執行
exec ${CMD}

