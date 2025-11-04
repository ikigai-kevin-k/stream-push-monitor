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

// FFmpeg 庫函數處理
// avcodec_send_packet - 發送封包到解碼器
int avcodec_send_packet_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "avcodec_send_packet");
}

int avcodec_send_packet_return(struct pt_regs *ctx) {
    struct jitterbuffer_metrics *metrics;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), "avcodec_send_packet");
    
    metrics = jitterbuffer_stats.lookup(&key);
    if (metrics) {
        metrics->packet_count++;
        // 檢查返回值（0 表示成功，負數表示錯誤）
        long ret = PT_REGS_RC(ctx);
        if (ret < 0) {
            metrics->dropped_packets++;
        }
    }
    
    return probe_jitterbuffer_return(ctx, "avcodec_send_packet");
}

// avcodec_receive_frame - 從解碼器接收幀
int avcodec_receive_frame_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "avcodec_receive_frame");
}

int avcodec_receive_frame_return(struct pt_regs *ctx) {
    struct jitterbuffer_metrics *metrics;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), "avcodec_receive_frame");
    
    metrics = jitterbuffer_stats.lookup(&key);
    if (metrics) {
        // 檢查返回值（0 表示成功，負數表示錯誤）
        long ret = PT_REGS_RC(ctx);
        if (ret < 0) {
            metrics->dropped_packets++;
        }
    }
    
    return probe_jitterbuffer_return(ctx, "avcodec_receive_frame");
}

// av_packet_alloc - 分配封包
int av_packet_alloc_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "av_packet_alloc");
}

int av_packet_alloc_return(struct pt_regs *ctx) {
    return probe_jitterbuffer_return(ctx, "av_packet_alloc");
}

// av_packet_ref - 引用封包
int av_packet_ref_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "av_packet_ref");
}

int av_packet_ref_return(struct pt_regs *ctx) {
    return probe_jitterbuffer_return(ctx, "av_packet_ref");
}

// av_packet_unref - 釋放封包
int av_packet_unref_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "av_packet_unref");
}

int av_packet_unref_return(struct pt_regs *ctx) {
    return probe_jitterbuffer_return(ctx, "av_packet_unref");
}

// av_bsf_send_packet - 發送封包到 bitstream filter
int av_bsf_send_packet_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "av_bsf_send_packet");
}

int av_bsf_send_packet_return(struct pt_regs *ctx) {
    struct jitterbuffer_metrics *metrics;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), "av_bsf_send_packet");
    
    metrics = jitterbuffer_stats.lookup(&key);
    if (metrics) {
        metrics->packet_count++;
        // 檢查返回值
        long ret = PT_REGS_RC(ctx);
        if (ret < 0) {
            metrics->dropped_packets++;
        }
    }
    
    return probe_jitterbuffer_return(ctx, "av_bsf_send_packet");
}

// av_bsf_receive_packet - 從 bitstream filter 接收封包
int av_bsf_receive_packet_entry(struct pt_regs *ctx) {
    return probe_jitterbuffer_entry(ctx, "av_bsf_receive_packet");
}

int av_bsf_receive_packet_return(struct pt_regs *ctx) {
    struct jitterbuffer_metrics *metrics;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;
    u32 tid = (u32)pid_tgid;
    
    struct jitterbuffer_key key = {};
    key.pid = pid;
    key.tid = tid;
    bpf_probe_read_kernel_str(&key.function_name, sizeof(key.function_name), "av_bsf_receive_packet");
    
    metrics = jitterbuffer_stats.lookup(&key);
    if (metrics) {
        metrics->packet_count++;
        // 檢查返回值
        long ret = PT_REGS_RC(ctx);
        if (ret < 0) {
            metrics->dropped_packets++;
        }
    }
    
    return probe_jitterbuffer_return(ctx, "av_bsf_receive_packet");
}

