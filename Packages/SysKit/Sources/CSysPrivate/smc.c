// AppleSMC 只读访问（CPU 模块设计 §3，参考 research/probes/cpu-module/thermal-power/smc_ro.h）。
//
// 用户客户端的结构体布局与命令字节是未公开约定。读写共用 selector 2，所以「只读」靠命令白名单保证：
// smc_call 只接受 CSP_SMC_CMD_* 三个读命令，本文件里没有写命令（D18）。

#include "CSysPrivate.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct {
    char major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize, dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

enum { kSMCUserClientSelector = 2 };

int csp_smc_command_allowed(uint8_t command) {
    return command == CSP_SMC_CMD_READ_KEY || command == CSP_SMC_CMD_GET_KEY_FROM_INDEX ||
           command == CSP_SMC_CMD_GET_KEY_INFO;
}

static kern_return_t smc_call(uint32_t connection, SMCParam *in, SMCParam *out) {
    if (!csp_smc_command_allowed(in->data8)) return kIOReturnNotPermitted;
    size_t size = sizeof(SMCParam);
    return IOConnectCallStructMethod(connection, kSMCUserClientSelector, in, sizeof(SMCParam), out, &size);
}

int csp_smc_open(uint32_t *connection) {
    *connection = 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr == KERN_SUCCESS) *connection = conn;
    return kr;
}

void csp_smc_close(uint32_t connection) {
    if (connection) IOServiceClose(connection);
}

int csp_smc_get_key_info(uint32_t connection, uint32_t key, csp_smc_key_info *info) {
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = CSP_SMC_CMD_GET_KEY_INFO;
    kern_return_t kr = smc_call(connection, &in, &out);
    info->data_size = out.keyInfo.dataSize;
    info->data_type = out.keyInfo.dataType;
    info->data_attributes = out.keyInfo.dataAttributes;
    info->result = out.result;
    return kr;
}

int csp_smc_read_key(uint32_t connection, uint32_t key, uint32_t data_size, uint8_t bytes[32], uint8_t *result) {
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = data_size;
    in.data8 = CSP_SMC_CMD_READ_KEY;
    kern_return_t kr = smc_call(connection, &in, &out);
    *result = out.result;
    memcpy(bytes, out.bytes, 32);
    return kr;
}

int csp_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t *key, uint8_t *result) {
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.data8 = CSP_SMC_CMD_GET_KEY_FROM_INDEX;
    in.data32 = index;
    kern_return_t kr = smc_call(connection, &in, &out);
    *key = out.key;
    *result = out.result;
    return kr;
}
