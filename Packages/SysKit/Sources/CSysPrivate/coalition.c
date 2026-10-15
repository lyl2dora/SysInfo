// resource coalition 的薄封装（CPU 模块设计 §3、边界稿 §7.4，参考 research/probes/cpu-module/processes/coal.h）。
// 三个函数在 libsystem 里但没有公开头文件，运行时用 dlsym 解析。

#include "CSysPrivate.h"

#include <dlfcn.h>
#include <libproc.h>
#include <pthread.h>
#include <string.h>

typedef int (*coal_list_fn)(int flavor, int type, void *buffer, int buffer_size);
typedef int (*coal_usage_fn)(uint64_t cid, void *buffer, size_t size);
typedef int (*coal_pids_fn)(uint64_t cid, void *pids, size_t *size);

static coal_list_fn coal_list;
static coal_usage_fn coal_usage;
static coal_pids_fn coal_pids;
static pthread_once_t coal_once = PTHREAD_ONCE_INIT;

static void coal_load(void) {
    coal_list = (coal_list_fn)dlsym(RTLD_DEFAULT, "proc_listcoalitions");
    coal_usage = (coal_usage_fn)dlsym(RTLD_DEFAULT, "coalition_info_resource_usage");
    coal_pids = (coal_pids_fn)dlsym(RTLD_DEFAULT, "coalition_info_pid_list");
}

int csp_coal_available(void) {
    pthread_once(&coal_once, coal_load);
    return coal_list && coal_usage && coal_pids;
}

enum {
    kListFlavorSingleType = 2,    // proc_listcoalitions 的 LISTCOALITIONS_SINGLE_TYPE：只列第二个参数指定的类型
    kCoalitionTypeResource = 0,   // COALITION_TYPE_RESOURCE
    kPidCoalitionInfo = 20,       // PROC_PIDCOALITIONINFO
};

int csp_coal_list(csp_coal_entry *buffer, int buffer_size) {
    if (!csp_coal_available()) return -1;
    return coal_list(kListFlavorSingleType, kCoalitionTypeResource, buffer, buffer ? buffer_size : 0);
}

int csp_coal_resource_usage(uint64_t coalition_id, void *buffer, size_t buffer_size) {
    if (!csp_coal_available()) return -1;
    return coal_usage(coalition_id, buffer, buffer_size);
}

int csp_coal_resource_usage_probe(uint64_t coalition_id, void *buffer, size_t buffer_size, size_t *bytes_written) {
    *bytes_written = 0;
    if (!csp_coal_available()) return -1;
    // 先后用两种哨兵各调用一次，取较大者，排除数据本身恰好等于哨兵的情况。
    static const uint8_t patterns[2] = {0xA5, 0x5A};
    size_t written = 0;
    for (int k = 0; k < 2; k++) {
        memset(buffer, patterns[k], buffer_size);
        int rc = coal_usage(coalition_id, buffer, buffer_size);
        if (rc != 0) return rc;
        const uint8_t *bytes = buffer;
        size_t last = 0;
        for (size_t i = 0; i < buffer_size; i++)
            if (bytes[i] != patterns[k]) last = i + 1;
        if (last > written) written = last;
    }
    *bytes_written = written;
    return 0;
}

int csp_coal_pid_list(uint64_t coalition_id, pid_t *buffer, size_t *size) {
    if (!csp_coal_available()) return -1;
    return coal_pids(coalition_id, buffer, size);
}

int csp_coal_of_pid(pid_t pid, uint64_t *coalition_id) {
    struct {
        uint64_t coalition_id[2];
        uint64_t reserved1, reserved2, reserved3;
    } info;
    memset(&info, 0, sizeof info);
    *coalition_id = 0;
    if (proc_pidinfo(pid, kPidCoalitionInfo, 0, &info, sizeof info) != (int)sizeof info) return -1;
    *coalition_id = info.coalition_id[kCoalitionTypeResource];
    return 0;
}
