// CSysStorage：存储模块的公开 IOKit C 封装（存储模块设计 §4.3）。
//
// NVMe SMART 走公开头 IOKit/storage/nvme/NVMeSMARTLibExternal.h 的 CFPlugIn 接口（COM 风格的函数表），
// Swift 直接调用不方便，所以放在这一层。这里只有公开接口，不涉及私有 API（私有 API 只在 CSysPrivate，D05）。
// 只读：只调用 SMARTReadData、GetIdentifyData，不发任何会改变设备状态的命令（D54）。

#ifndef CSYSSTORAGE_H
#define CSYSSTORAGE_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

/// SMART / Health 日志与 Identify Controller 的字节数（NVMe 规范）。
#define CST_SMART_LOG_SIZE 512
#define CST_IDENTIFY_SIZE 4096

/// 一个打开的 SMART 连接（plugin 常驻，D55）。
typedef struct cst_smart_handle cst_smart_handle;

/// 为一块 `IOBlockStorageDevice`（须为 NVMe SMART Capable）打开 SMART 接口。失败时返回 NULL，并在 `result` 里给出 kern_return / HRESULT。
cst_smart_handle * _Nullable cst_smart_open(io_service_t device, int32_t * _Nullable result);

/// 关闭连接；传 NULL 没有副作用。
void cst_smart_close(cst_smart_handle * _Nullable handle);

/// 读 SMART / Health 日志（512 字节）。返回 IOReturn，0 为成功。
int32_t cst_smart_read(cst_smart_handle * _Nonnull handle, uint8_t buffer[_Nonnull CST_SMART_LOG_SIZE]);

/// 读 Identify Controller（4096 字节）。返回 IOReturn，0 为成功。
int32_t cst_smart_identify(cst_smart_handle * _Nonnull handle, uint8_t buffer[_Nonnull CST_IDENTIFY_SIZE]);

#ifdef __cplusplus
}
#endif

#endif
