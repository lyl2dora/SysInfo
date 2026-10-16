// NVMe SMART 的公开 CFPlugIn 封装（见 CSysStorage.h）。

#include "CSysStorage.h"

#include <stdlib.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

struct cst_smart_handle {
    IOCFPlugInInterface **plugin;
    IONVMeSMARTInterface **smart;
};

cst_smart_handle *cst_smart_open(io_service_t device, int32_t *result) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        device, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        if (result) *result = kr != KERN_SUCCESS ? kr : -1;
        return NULL;
    }
    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        if (result) *result = hr != S_OK ? (int32_t)hr : -1;
        return NULL;
    }
    cst_smart_handle *handle = calloc(1, sizeof(cst_smart_handle));
    if (handle == NULL) {
        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        if (result) *result = -1;
        return NULL;
    }
    handle->plugin = plugin;
    handle->smart = smart;
    if (result) *result = 0;
    return handle;
}

void cst_smart_close(cst_smart_handle *handle) {
    if (handle == NULL) return;
    if (handle->smart) (*handle->smart)->Release(handle->smart);
    if (handle->plugin) IODestroyPlugInInterface(handle->plugin);
    free(handle);
}

int32_t cst_smart_read(cst_smart_handle *handle, uint8_t buffer[CST_SMART_LOG_SIZE]) {
    _Static_assert(sizeof(NVMeSMARTData) <= CST_SMART_LOG_SIZE, "NVMeSMARTData larger than the log page");
    NVMeSMARTData data;
    memset(&data, 0, sizeof data);
    IOReturn r = (*handle->smart)->SMARTReadData(handle->smart, &data);
    memset(buffer, 0, CST_SMART_LOG_SIZE);
    if (r == kIOReturnSuccess) memcpy(buffer, &data, sizeof data);
    return r;
}

int32_t cst_smart_identify(cst_smart_handle *handle, uint8_t buffer[CST_IDENTIFY_SIZE]) {
    _Static_assert(sizeof(NVMeIdentifyControllerStruct) <= CST_IDENTIFY_SIZE, "identify larger than 4096");
    NVMeIdentifyControllerStruct identify;
    memset(&identify, 0, sizeof identify);
    IOReturn r = (*handle->smart)->GetIdentifyData(handle->smart, &identify, 0);
    memset(buffer, 0, CST_IDENTIFY_SIZE);
    if (r == kIOReturnSuccess) memcpy(buffer, &identify, sizeof identify);
    return r;
}
