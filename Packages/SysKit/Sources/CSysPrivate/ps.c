// 电源设备的私有 IOPS 接口（D22、D84，电源设备设计 §3）。
// IOPSCopyPowerSourcesByType 与 IOPSAccNotificationCreateRunLoopSource 在 IOKit 里但没有公开头文件，运行时用 dlsym 解析。
// 返回的 blob 与公开 IOPSCopyPowerSourcesInfo 的格式相同，交给公开的 IOPSCopyPowerSourcesList / IOPSGetPowerSourceDescription 解析。
// 只读：不创建、不修改任何电源。

#include "CSysPrivate.h"

#include <dlfcn.h>
#include <pthread.h>

typedef CFTypeRef (*ps_by_type_fn)(int type);
typedef CFRunLoopSourceRef (*ps_acc_notify_fn)(void (*callback)(void *), void *context);

static ps_by_type_fn ps_by_type;
static ps_acc_notify_fn ps_acc_notify;
static pthread_once_t ps_once = PTHREAD_ONCE_INIT;

static void ps_load(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_NOLOAD);
    if (!iokit) iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit) return;
    ps_by_type = (ps_by_type_fn)dlsym(iokit, "IOPSCopyPowerSourcesByType");
    ps_acc_notify = (ps_acc_notify_fn)dlsym(iokit, "IOPSAccNotificationCreateRunLoopSource");
}

int csp_ps_available(void) {
    pthread_once(&ps_once, ps_load);
    return ps_by_type != NULL;
}

CFTypeRef csp_ps_copy_by_type(int type) {
    if (!csp_ps_available()) return NULL;
    return ps_by_type(type);
}

int csp_ps_acc_notify_available(void) {
    pthread_once(&ps_once, ps_load);
    return ps_acc_notify != NULL;
}

CFRunLoopSourceRef csp_ps_acc_notify_create(void (*callback)(void *), void *context) {
    if (!csp_ps_acc_notify_available()) return NULL;
    return ps_acc_notify(callback, context);
}
