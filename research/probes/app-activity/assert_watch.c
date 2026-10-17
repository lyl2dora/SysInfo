// assert_watch.c - 应用活动模块：电源断言（谁在阻止睡眠）的补测（只读为主）。
// 在 power/assert_probe.swift（2026-09-28，M5 只读一次）的基础上补：
//   1) IOPMCopyAssertionsByProcess / IOPMCopyAssertionsStatus 的开销（线程 CPU，中位数）；
//   2) 断言归属：pid → uid、resource coalition（PROC_PIDCOALITIONINFO 对其他用户 / root 进程是否可读）、
//      AssertionOnBehalfOfPID（代他人持有，如 coreaudiod）、超时、AssertType 与 AssertionTrueType 的差别；
//   3) 变化通知：notify(3) 的三个未文档名字能不能收到「断言出现 / 消失」，延迟多少；
//      为此本探针**自己**创建一个 PreventUserIdleSystemSleep 断言约 3 s 后释放（只影响空闲睡眠，不改设置）；
//   4) 私有的断言活动日志 IOPMCopyAssertionActivityLog / IOPMCopyAssertionActivityUpdate 能不能读、是否默认开启；
//      只读，不调用 IOPMSetAssertionActivityLog；
//   5) 内核侧断言：IOPMrootDomain 的 DriverPMAssertionsDetailed（Level 非 0 的条目）。
// build: xcrun clang -O2 -framework IOKit -framework CoreFoundation assert_watch.c -o assert_watch
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <notify.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;

static uint64_t tcpu_ns(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
static uint64_t mono_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int cmp_u64(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }

static void cs(CFTypeRef s, char *b, int n) {
    b[0] = 0;
    if (s && CFGetTypeID(s) == CFStringGetTypeID()) CFStringGetCString(s, b, n, kCFStringEncodingUTF8);
}
static long long cnum(CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    long long out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongLongType, &out);
    return out;
}
static void cstr(CFDictionaryRef d, const char *key, char *b, int n) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    cs(CFDictionaryGetValue(d, k), b, n);
    CFRelease(k);
}

static uint64_t coal_of(pid_t pid, int *ok) {
    struct { uint64_t id[2]; uint64_t r1, r2, r3; } info = {0};
    int n = proc_pidinfo(pid, 20, 0, &info, sizeof info);
    *ok = n == (int)sizeof info;
    return info.id[0];
}

static int count_assertions(int verbose) {
    CFDictionaryRef byProc = NULL;
    if (IOPMCopyAssertionsByProcess(&byProc) != kIOReturnSuccess || !byProc) return -1;
    CFIndex n = CFDictionaryGetCount(byProc);
    const void **keys = calloc(n, sizeof *keys), **vals = calloc(n, sizeof *vals);
    CFDictionaryGetKeysAndValues(byProc, keys, vals);
    int total = 0;
    for (CFIndex i = 0; i < n; i++) {
        int pid = -1;
        CFNumberGetValue(keys[i], kCFNumberIntType, &pid);
        CFArrayRef arr = vals[i];
        for (CFIndex j = 0; j < CFArrayGetCount(arr); j++) {
            total++;
            if (!verbose) continue;
            CFDictionaryRef a = CFArrayGetValueAtIndex(arr, j);
            char type[96], trueType[96], pname[96], name[160];
            cstr(a, "AssertType", type, sizeof type);
            cstr(a, "AssertionTrueType", trueType, sizeof trueType);
            cstr(a, "Process Name", pname, sizeof pname);
            cstr(a, "AssertName", name, sizeof name);
            long long level = cnum(a, "AssertLevel"), behalf = cnum(a, "AssertionOnBehalfOfPID");
            long long timeout = cnum(a, "TimeoutSeconds");
            struct proc_bsdshortinfo si;
            int uidok = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) == (int)sizeof si;
            int cok = 0;
            uint64_t cid = coal_of(pid, &cok);
            char uid[16];
            if (uidok) snprintf(uid, sizeof uid, "%u", si.pbsi_uid); else snprintf(uid, sizeof uid, "?");
            printf("  pid=%-6d uid=%-4s cid=%-6llu%s %-28s true=%-28s lvl=%lld behalf=%lld timeout=%lld proc=%s name=\"%.60s\"\n",
                pid, uid, (unsigned long long)cid, cok ? "" : "(FAIL)", type, trueType, level, behalf, timeout, pname, name);
        }
    }
    free(keys);
    free(vals);
    CFRelease(byProc);
    return total;
}

static void cost(const char *label, int which) {
    enum { N = 60 };
    uint64_t c[N], w[N];
    for (int i = 0; i < N; i++) {
        uint64_t c0 = tcpu_ns(), w0 = mono_ns();
        if (which == 0) {
            CFDictionaryRef d = NULL;
            IOPMCopyAssertionsByProcess(&d);
            if (d) CFRelease(d);
        } else {
            CFDictionaryRef d = NULL;
            IOPMCopyAssertionsStatus(&d);
            if (d) CFRelease(d);
        }
        c[i] = tcpu_ns() - c0;
        w[i] = mono_ns() - w0;
        usleep(20000);
    }
    qsort(c, N, sizeof *c, cmp_u64);
    qsort(w, N, sizeof *w, cmp_u64);
    printf("cost %-34s thread CPU median %.3f ms p90 %.3f | wall median %.3f ms p90 %.3f\n", label, c[N / 2] / 1e6,
        c[N * 9 / 10] / 1e6, w[N / 2] / 1e6, w[N * 9 / 10] / 1e6);
}

static const char *notifyNames[] = {
    "com.apple.system.powermanagement.assertions.anychange",
    "com.apple.system.powermanagement.assertions",
    "com.apple.system.powermanagement.assertions.timeout",
    "com.apple.system.powermanagement.assertionresync",
};
enum { NN = sizeof notifyNames / sizeof *notifyNames };

static void notify_poll(int *tok, const char *phase, uint64_t t0) {
    // 1 ms 粒度轮询 notify_check，最多 1.5 s，记录每个名字第一次触发的延迟。
    uint64_t first[NN] = {0};
    uint64_t end = mono_ns() + 1500000000ull;
    while (mono_ns() < end) {
        for (int i = 0; i < NN; i++) {
            if (tok[i] < 0 || first[i]) continue;
            int changed = 0;
            if (notify_check(tok[i], &changed) == NOTIFY_STATUS_OK && changed) first[i] = mono_ns();
        }
        usleep(1000);
    }
    for (int i = 0; i < NN; i++) {
        if (tok[i] < 0) continue;
        if (first[i]) printf("  %-8s %-56s fired after %.1f ms\n", phase, notifyNames[i], (first[i] - t0) / 1e6);
        else printf("  %-8s %-56s no notification within 1.5 s\n", phase, notifyNames[i]);
    }
}

typedef IOReturn (*log_fn)(CFArrayRef *, bool *);
typedef IOReturn (*upd_fn)(CFArrayRef *, bool *, uint32_t *);

static void dump_log_entries(CFArrayRef arr, int max) {
    if (!arr) return;
    CFIndex n = CFArrayGetCount(arr);
    printf("  entries=%ld\n", (long)n);
    for (CFIndex i = n > max ? n - max : 0; i < n; i++) {
        CFTypeRef e = CFArrayGetValueAtIndex(arr, i);
        if (CFGetTypeID(e) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef d = e;
        CFIndex kn = CFDictionaryGetCount(d);
        const void **ks = calloc(kn, sizeof *ks), **vs = calloc(kn, sizeof *vs);
        CFDictionaryGetKeysAndValues(d, ks, vs);
        printf("   -");
        for (CFIndex k = 0; k < kn; k++) {
            char kb[64], vb[96];
            cs(ks[k], kb, sizeof kb);
            if (CFGetTypeID(vs[k]) == CFStringGetTypeID()) cs(vs[k], vb, sizeof vb);
            else if (CFGetTypeID(vs[k]) == CFNumberGetTypeID()) { long long x = 0; CFNumberGetValue(vs[k], kCFNumberLongLongType, &x); snprintf(vb, sizeof vb, "%lld", x); }
            else if (CFGetTypeID(vs[k]) == CFDateGetTypeID()) snprintf(vb, sizeof vb, "date(%.0f)", CFDateGetAbsoluteTime(vs[k]));
            else snprintf(vb, sizeof vb, "<type %lu>", CFGetTypeID(vs[k]));
            printf(" %s=%.50s", kb, vb);
        }
        printf("\n");
        free(ks);
        free(vs);
    }
}

int main(int argc, char **argv) {
    // argv[1]：自建断言的类型，默认 PreventUserIdleSystemSleep；传 PreventUserIdleDisplaySleep 可测「汇总状态 0→1」的情形。
    CFStringRef ownType = argc > 1 ? CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8) : kIOPMAssertPreventUserIdleSystemSleep;
    printf("== 1. current assertions (by process) ==\n");
    int total = count_assertions(1);
    printf("total assertions: %d\n\n", total);

    printf("== 2. cost ==\n");
    cost("IOPMCopyAssertionsByProcess", 0);
    cost("IOPMCopyAssertionsStatus", 1);

    printf("\n== 3. kernel-side assertions (IOPMrootDomain DriverPMAssertionsDetailed) ==\n");
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (root) {
        uint64_t c0 = tcpu_ns();
        CFTypeRef det = IORegistryEntryCreateCFProperty(root, CFSTR("DriverPMAssertionsDetailed"), NULL, 0);
        printf("read cost %.3f ms\n", (tcpu_ns() - c0) / 1e6);
        if (det && CFGetTypeID(det) == CFArrayGetTypeID()) {
            CFIndex n = CFArrayGetCount(det), active = 0;
            for (CFIndex i = 0; i < n; i++) {
                CFDictionaryRef a = CFArrayGetValueAtIndex(det, i);
                long long level = cnum(a, "Level");
                char owner[128], name[96];
                cstr(a, "ModuleName", owner, sizeof owner);
                cstr(a, "Name", name, sizeof name);
                if (level != 0) active++;
                printf("  level=%lld assertions=0x%llx owner=%s name=%s\n", level, cnum(a, "Assertions"), owner, name);
            }
            printf("  %ld entries, %ld with level != 0\n", (long)n, (long)active);
        } else printf("  property absent\n");
        if (det) CFRelease(det);
        IOObjectRelease(root);
    }

    printf("\n== 4. private activity log (read only) ==\n");
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    log_fn copyLog = (log_fn)dlsym(iokit, "IOPMCopyAssertionActivityLog");
    upd_fn copyUpd = (upd_fn)dlsym(iokit, "IOPMCopyAssertionActivityUpdate");
    printf("IOPMCopyAssertionActivityLog %s, IOPMCopyAssertionActivityUpdate %s\n", copyLog ? "present" : "absent", copyUpd ? "present" : "absent");
    uint32_t refCnt = 0;
    if (copyLog) {
        CFArrayRef arr = NULL;
        bool overflow = false;
        uint64_t c0 = tcpu_ns();
        IOReturn kr = copyLog(&arr, &overflow);
        printf("ActivityLog kr=0x%x overflow=%d cost %.3f ms\n", kr, overflow, (tcpu_ns() - c0) / 1e6);
        dump_log_entries(arr, 6);
        if (arr) CFRelease(arr);
    }
    if (copyUpd) {
        CFArrayRef arr = NULL;
        bool overflow = false;
        IOReturn kr = copyUpd(&arr, &overflow, &refCnt);
        printf("ActivityUpdate(ref 0) kr=0x%x overflow=%d refCnt->%u\n", kr, overflow, refCnt);
        dump_log_entries(arr, 3);
        if (arr) CFRelease(arr);
    }

    printf("\n== 5. change notification (own assertion, ~3 s) ==\n");
    int tok[NN];
    for (int i = 0; i < NN; i++) {
        if (notify_register_check(notifyNames[i], &tok[i]) != NOTIFY_STATUS_OK) tok[i] = -1;
        int changed;
        if (tok[i] >= 0) notify_check(tok[i], &changed);  // 第一次 check 总是返回 changed，先清掉
    }
    notify_poll(tok, "idle", mono_ns());
    // 私有的 IOPMAssertionNotify(name, req)：向 powerd 登记「我要这个通知」（kIOPMNotifyRegister = 1），进程退出即失效。
    // 未登记时 powerd 可能不发 anychange（27.0.1 实测：未登记时自建 / 释放断言都收不到）。
    typedef IOReturn (*an_fn)(const char *, int);
    an_fn assertNotify = (an_fn)dlsym(iokit, "IOPMAssertionNotify");
    if (getenv("REGISTER") && assertNotify) {
        for (int i = 0; i < 2; i++) printf("IOPMAssertionNotify(%s, register) kr=0x%x\n", notifyNames[i], assertNotify(notifyNames[i], 1));
        notify_poll(tok, "regd", mono_ns());
    } else printf("IOPMAssertionNotify %s (set REGISTER=1 to call)\n", assertNotify ? "present" : "absent");
    IOPMAssertionID aid = 0;
    uint64_t t0 = mono_ns();
    IOReturn kr = IOPMAssertionCreateWithName(ownType, kIOPMAssertionLevelOn,
        CFSTR("SysInfo probe (app-activity, 3 s)"), &aid);
    printf("create kr=0x%x id=%u\n", kr, aid);
    notify_poll(tok, "create", t0);
    printf("assertions now: %d; own pid %d listed:\n", count_assertions(0), getpid());
    {
        CFDictionaryRef d = NULL;
        IOPMCopyAssertionsByProcess(&d);
        int me = getpid();
        CFNumberRef k = CFNumberCreate(NULL, kCFNumberIntType, &me);
        printf("  %s\n", d && CFDictionaryContainsKey(d, k) ? "yes" : "NO");
        CFRelease(k);
        if (d) CFRelease(d);
    }
    sleep(1);
    t0 = mono_ns();
    kr = IOPMAssertionRelease(aid);
    printf("release kr=0x%x\n", kr);
    notify_poll(tok, "release", t0);
    printf("assertions now: %d\n", count_assertions(0));
    if (copyUpd) {
        CFArrayRef arr = NULL;
        bool overflow = false;
        uint32_t before = refCnt;
        IOReturn k2 = copyUpd(&arr, &overflow, &refCnt);
        printf("ActivityUpdate(ref %u) kr=0x%x overflow=%d refCnt->%u\n", before, k2, overflow, refCnt);
        dump_log_entries(arr, 4);
        if (arr) CFRelease(arr);
    }
    // 别的进程的断言：派生 caffeinate -d -t 1（1 s 后自行退出），看 anychange 是否同样触发。
    {
        pid_t child;
        char *args[] = {"/usr/bin/caffeinate", "-d", "-t", "1", NULL};
        uint64_t t1 = mono_ns();
        if (posix_spawn(&child, args[0], NULL, NULL, args, environ) == 0) {
            notify_poll(tok, "ext-on", t1);
            int st;
            waitpid(child, &st, 0);
            notify_poll(tok, "ext-off", mono_ns());
        }
    }
    for (int i = 0; i < NN; i++) if (tok[i] >= 0) notify_cancel(tok[i]);
    return 0;
}
