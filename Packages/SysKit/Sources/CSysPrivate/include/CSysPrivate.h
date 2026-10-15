// CSysPrivate：SysInfo 的私有 C 层（D05、D23、D26，CPU 模块设计 §3）。
//
// 规则：
// - 所有私有接口（IOReport、AppleSMC 的结构体约定、resource coalition、私有 proc_pidinfo flavor …）只出现在这一层；
// - 私有函数一律在运行时用 dlopen/dlsym 解析，不在链接期依赖私有库：系统去掉某个符号时，
//   对应的 csp_*_available() 返回 0，上层回退或显示不可用，app 本身照常启动（D05）；
// - 对上只暴露 csp_* 封装函数，不暴露私有符号本身；C 里只做调用和返回值检查，业务逻辑放在 Swift 层；
// - 只有 SysCollectors 可以依赖它。下游（app、CLI）在编译器层面也能看到这份 module map，
//   隔离靠 scripts/check-private-imports.sh 的构建期检查（D26）。
//
// 每次增删本文件中的函数时递增 CSP_LAYER_VERSION。

#ifndef CSYSPRIVATE_H
#define CSYSPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CSP_LAYER_VERSION 1

/// 私有 C 层的接口版本号，诊断页和 sysinfo-cli 据此确认链接到的是哪一版私有层。
uint32_t csp_layer_version(void);

// MARK: - IOReport（/usr/lib/libIOReport.dylib）

/// IOReport 的全部所需符号都解析到时返回 1。
int csp_ior_available(void);

/// 枚举某个组（可选子组）的全部通道。组名为 NULL 表示全部组。调用方负责释放。
CFMutableDictionaryRef _Nullable csp_ior_copy_channels_in_group(CFStringRef _Nullable group,
                                                                CFStringRef _Nullable subgroup) CF_RETURNS_RETAINED;

/// 把 `source` 的通道并入 `dest`（同一驱动的组合并进一个订阅，开销约等于最贵的一组）。
void csp_ior_merge_channels(CFMutableDictionaryRef _Nonnull dest, CFDictionaryRef _Nonnull source);

/// 一个 IOReport 订阅：订阅句柄加上订阅到的通道字典。不透明类型，由 csp_ior_subscription_destroy 释放。
typedef struct csp_ior_subscription csp_ior_subscription;

/// 订阅 `channels` 里的全部通道；失败返回 NULL。
csp_ior_subscription * _Nullable csp_ior_subscription_create(CFMutableDictionaryRef _Nonnull channels);
void csp_ior_subscription_destroy(csp_ior_subscription * _Nullable subscription);
/// 订阅实际包含的通道数。
long csp_ior_subscription_channel_count(const csp_ior_subscription * _Nonnull subscription);

/// 取一次样本（各通道的累计值）。调用方负责释放。
CFDictionaryRef _Nullable csp_ior_subscription_sample(csp_ior_subscription * _Nonnull subscription) CF_RETURNS_RETAINED;

/// 两次样本的差。调用方负责释放。
CFDictionaryRef _Nullable csp_ior_samples_delta(CFDictionaryRef _Nonnull earlier,
                                                CFDictionaryRef _Nonnull later) CF_RETURNS_RETAINED;

/// 单个通道（样本或通道字典里 "IOReportChannels" 数组的元素）的属性。返回值不归调用方所有。
CFStringRef _Nullable csp_ior_channel_group(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable csp_ior_channel_subgroup(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable csp_ior_channel_name(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable csp_ior_channel_driver_name(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable csp_ior_channel_unit_label(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
uint64_t csp_ior_channel_id(CFDictionaryRef _Nonnull channel);

/// 状态类通道（如 CPU Performance States）：状态数、第 i 个状态的名字和驻留（timebase tick）。
int32_t csp_ior_state_count(CFDictionaryRef _Nonnull channel);
CFStringRef _Nullable csp_ior_state_name(CFDictionaryRef _Nonnull channel, int32_t index) CF_RETURNS_NOT_RETAINED;
int64_t csp_ior_state_residency(CFDictionaryRef _Nonnull channel, int32_t index);

/// 简单计数类通道（如 Interrupt Statistics、Energy Model）的整数值。
int64_t csp_ior_simple_integer(CFDictionaryRef _Nonnull channel);

// MARK: - AppleSMC（只读）
//
// 读写走同一个 IOConnectCallStructMethod selector（2），区别只在命令字节。本层只定义三个读命令，
// 并在发起调用前检查命令白名单，写命令（kSMCWriteKey）在代码里不存在（D18：不写 SMC）。

#define CSP_SMC_CMD_READ_KEY 5
#define CSP_SMC_CMD_GET_KEY_FROM_INDEX 8
#define CSP_SMC_CMD_GET_KEY_INFO 9

/// `command` 在只读白名单里时返回 1。供单测核对写命令被拒绝。
int csp_smc_command_allowed(uint8_t command);

/// 打开 AppleSMC 的用户客户端。成功返回 0（KERN_SUCCESS），`*connection` 为连接。
int csp_smc_open(uint32_t * _Nonnull connection);
void csp_smc_close(uint32_t connection);

/// 键的元信息。`result` 是 SMC 自己的结果字节，0 表示成功。
typedef struct {
    uint32_t data_size;
    uint32_t data_type;      // 四字符类型码，如 'flt '
    uint8_t data_attributes; // 位 0x04 置位表示小端（调研报告 §1.6）
    uint8_t result;
} csp_smc_key_info;

/// 返回 IOKit 的 kern_return_t；SMC 层面的错误看 `info->result`。
int csp_smc_get_key_info(uint32_t connection, uint32_t key, csp_smc_key_info * _Nonnull info);

/// 读一个键的原始字节（最多 32 字节）。`data_size` 取自缓存的 key-info。
/// 返回 kern_return_t；`*result` 为 SMC 的结果字节。
int csp_smc_read_key(uint32_t connection, uint32_t key, uint32_t data_size, uint8_t bytes[_Nonnull 32],
                     uint8_t * _Nonnull result);

/// 第 `index` 个键的四字符码（枚举用）。返回 kern_return_t；`*result` 为 SMC 的结果字节。
int csp_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t * _Nonnull key, uint8_t * _Nonnull result);

// MARK: - resource coalition（libsystem 未公开的函数，dlsym 解析）

/// proc_listcoalitions、coalition_info_resource_usage、coalition_info_pid_list 三个符号都解析到时返回 1（自检 S1）。
int csp_coal_available(void);

/// proc_listcoalitions(COALITION_TYPE_RESOURCE) 的一项，16 字节。
typedef struct {
    uint64_t coalition_id;
    uint32_t type;
    uint32_t tasks;
} csp_coal_entry;

/// 列出全部 resource coalition。`buffer` 为 NULL 时返回所需字节数；否则返回写入的字节数，失败返回 -1。
int csp_coal_list(csp_coal_entry * _Nullable buffer, int buffer_size);

/// 读 coalition 的资源用量槽位数组（uint64_t × N）。返回 0 表示成功。常规采样用这个，每次只调用一次。
int csp_coal_resource_usage(uint64_t coalition_id, void * _Nonnull buffer, size_t buffer_size);

/// 自检 S3 用：同 csp_coal_resource_usage，另用两种哨兵字节各调用一次，探测内核实际写出的字节数。
int csp_coal_resource_usage_probe(uint64_t coalition_id, void * _Nonnull buffer, size_t buffer_size,
                                  size_t * _Nonnull bytes_written);

/// 成员 pid 列表。`*size` 入参是缓冲字节数，出参是写入字节数；返回 0 表示成功。
/// 写入字节数等于缓冲大小时可能被截断，调用方应加倍重试（边界稿 §7.4）。
int csp_coal_pid_list(uint64_t coalition_id, pid_t * _Nonnull buffer, size_t * _Nonnull size);

/// 进程所在的 resource coalition id（proc_pidinfo 的 PROC_PIDCOALITIONINFO）。成功返回 0。
int csp_coal_of_pid(pid_t pid, uint64_t * _Nonnull coalition_id);

// MARK: - proc_pidinfo 的私有 flavor

/// 线程按 perflevel 拆分的计数（PROC_PIDTHREADCOUNTS，flavor 34）。只用于验证和自检，不进常规采样。
typedef struct {
    uint64_t instructions;
    uint64_t cycles;
    uint64_t user_time_mach;
    uint64_t system_time_mach;
    uint64_t energy_nj;
} csp_thread_counts_level;

/// 读本进程线程 `thread_id`（pthread_threadid_np 的值）在各 perflevel 上的计数，最多 `max_levels` 档。
/// 返回实际档数，失败返回 -1。
int csp_thread_counts(pid_t pid, uint64_t thread_id, csp_thread_counts_level * _Nonnull levels, int max_levels);

/// 进程的开机期间唯一 id（PROC_PIDUNIQIDENTIFIERINFO 的 p_uniqueid，不复用），用作名称缓存的键。成功返回 0。
int csp_proc_unique_id(pid_t pid, uint64_t * _Nonnull unique_id);

#ifdef __cplusplus
}
#endif

#endif /* CSYSPRIVATE_H */
