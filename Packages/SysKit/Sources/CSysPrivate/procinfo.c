// proc_pidinfo 的私有 flavor（CPU 模块设计 §3）。

#include "CSysPrivate.h"

#include <libproc.h>
#include <stdlib.h>
#include <string.h>

enum {
    kPidUniqueIdentifierInfo = 17,  // PROC_PIDUNIQIDENTIFIERINFO
    kPidThreadCounts = 34,          // PROC_PIDTHREADCOUNTS
    kMaxLevels = 8,
};

int csp_thread_counts(pid_t pid, uint64_t thread_id, csp_thread_counts_level *levels, int max_levels) {
    if (max_levels <= 0) return -1;
    if (max_levels > kMaxLevels) max_levels = kMaxLevels;
    struct {
        uint16_t length;      // 档数
        uint16_t reserved0;
        uint32_t reserved1;
        csp_thread_counts_level counts[kMaxLevels];
    } buffer;
    memset(&buffer, 0, sizeof buffer);
    int got = proc_pidinfo(pid, kPidThreadCounts, thread_id, &buffer, (int)sizeof buffer);
    if (got <= 8) return -1;
    int fromBytes = (got - 8) / (int)sizeof(csp_thread_counts_level);
    int n = buffer.length > 0 && buffer.length <= fromBytes ? buffer.length : fromBytes;
    if (n > max_levels) n = max_levels;
    memcpy(levels, buffer.counts, (size_t)n * sizeof(csp_thread_counts_level));
    return n;
}

int csp_proc_unique_id(pid_t pid, uint64_t *unique_id) {
    struct {
        uint8_t executable_uuid[16];
        uint64_t unique_id;
        uint64_t parent_unique_id;
        int32_t id_version;
        int32_t original_parent_id_version;
        uint64_t reserved2, reserved3;
    } info;
    memset(&info, 0, sizeof info);
    *unique_id = 0;
    if (proc_pidinfo(pid, kPidUniqueIdentifierInfo, 0, &info, sizeof info) != (int)sizeof info) return -1;
    *unique_id = info.unique_id;
    return 0;
}
