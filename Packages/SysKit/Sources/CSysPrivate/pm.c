// 电源断言变化通知的登记（D69，应用活动设计 §3.1）。
// IOPMAssertionNotify 在 IOKit 里但没有公开头文件，运行时用 dlsym 解析（D35）。
// powerd 只给登记过的进程发 com.apple.system.powermanagement.assertions.anychange（两台 27.0.1 实测），
// 登记随进程退出失效。不改变任何断言或电源设置。

#include "CSysPrivate.h"

#include <dlfcn.h>
#include <pthread.h>

typedef int (*pm_notify_fn)(const char *name, int request);

static pm_notify_fn pm_notify;
static pthread_once_t pm_once = PTHREAD_ONCE_INIT;

static void pm_load(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_NOLOAD);
    if (!iokit) iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (iokit) pm_notify = (pm_notify_fn)dlsym(iokit, "IOPMAssertionNotify");
}

int csp_pm_available(void) {
    pthread_once(&pm_once, pm_load);
    return pm_notify != NULL;
}

enum { kIOPMNotifyRegister = 0x1 };

int csp_pm_assertion_notify_register(const char *name) {
    if (!csp_pm_available()) return -1;
    return pm_notify(name, kIOPMNotifyRegister);
}
