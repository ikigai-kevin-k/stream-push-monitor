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
        """Attach uprobes to target binary and its libraries"""
        try:
            # 方案 1: 追蹤 FFmpeg 庫函數（推薦）
            # FFmpeg 庫函數 - 封包處理
            function_names = [
                'avcodec_send_packet',      # 發送封包到解碼器
                'avcodec_receive_frame',    # 從解碼器接收幀
                'av_packet_alloc',          # 分配封包
                'av_packet_ref',            # 引用封包
                'av_packet_unref',          # 釋放封包
                'av_bsf_send_packet',       # 發送封包到 bitstream filter
                'av_bsf_receive_packet',    # 從 bitstream filter 接收封包
            ]
            
            # 原始函數名稱（保留作為備選）
            legacy_function_names = [
                'jitterbuffer_put',
                'jitterbuffer_get',
                'rtp_parse_packet',
                'ff_rtp_parse_packet',
                'SrsRtpJitterBuffer::put',
                'SrsRtpJitterBuffer::get',
            ]
            
            # 動態庫路徑（FFmpeg 使用的庫）
            library_paths = [
                '/usr/lib/x86_64-linux-gnu/libavcodec.so.58',
                '/usr/lib/x86_64-linux-gnu/libavformat.so.58',
                '/usr/lib/x86_64-linux-gnu/libavutil.so.56',
            ]
            
            attached_functions = []
            
            # 首先嘗試在動態庫中附加
            for lib_path in library_paths:
                if not os.path.exists(lib_path):
                    continue
                
                for func_name in function_names:
                    try:
                        # 嘗試附加 entry probe
                        self.bpf.attach_uprobe(
                            name=lib_path,
                            sym=func_name,
                            fn_name=f"{func_name.replace('::', '_').replace('.', '_')}_entry"
                        )
                        
                        # 嘗試附加 return probe
                        self.bpf.attach_uretprobe(
                            name=lib_path,
                            sym=func_name,
                            fn_name=f"{func_name.replace('::', '_').replace('.', '_')}_return"
                        )
                        
                        attached_functions.append(f"{lib_path}:{func_name}")
                        print(f"Attached probe to {func_name} in {lib_path}")
                        
                    except Exception as e:
                        # 函數可能不存在，繼續嘗試下一個
                        continue
            
            # 然後嘗試在主二進制檔案中附加（包括原始函數名稱）
            for func_name in function_names + legacy_function_names:
                try:
                    # 嘗試附加 entry probe
                    self.bpf.attach_uprobe(
                        name=binary_path,
                        sym=func_name,
                        fn_name=f"{func_name.replace('::', '_').replace('.', '_')}_entry"
                    )
                    
                    # 嘗試附加 return probe
                    self.bpf.attach_uretprobe(
                        name=binary_path,
                        sym=func_name,
                        fn_name=f"{func_name.replace('::', '_').replace('.', '_')}_return"
                    )
                    
                    attached_functions.append(f"{binary_path}:{func_name}")
                    print(f"Attached probe to {func_name} in {binary_path}")
                    
                except Exception as e:
                    # 函數可能不存在，繼續嘗試下一個
                    continue
            
            if not attached_functions:
                print(f"Warning: Could not attach any probes to {binary_path} or its libraries")
                print("Please verify function names using: objdump -T <binary> | grep avcodec")
                print("Or check library symbols: nm -D /usr/lib/x86_64-linux-gnu/libavcodec.so.58 | grep avcodec_send_packet")
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

