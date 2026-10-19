// 电源设备模块边界探针：用公开 IOHIDManager / IOHIDDevice（C）读 UPS 的 feature 报告，与 CoreHID 对照开销。
// 只读（只用 GET_REPORT）。匹配限定 PrimaryUsagePage 0x84（D22）。
// 编译：xcrun clang -O2 -o out/ups_iohid ups_iohid.c -framework IOKit -framework CoreFoundation
// 用法：./ups_iohid [轮数，默认 20]
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

static double cpu_us(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1e6 + ru.ru_utime.tv_usec + ru.ru_stime.tv_usec;
}

static double wall_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 20;
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int page = 0x84;
    CFNumberRef pageNum = CFNumberCreate(NULL, kCFNumberIntType, &page);
    const void *keys[] = {CFSTR(kIOHIDPrimaryUsagePageKey)};
    const void *vals[] = {pageNum};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(mgr, match);
    double c0 = cpu_us();
    IOReturn kr = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    printf("IOHIDManagerOpen = 0x%x\n", kr);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    if (!set || CFSetGetCount(set) == 0) { printf("no device on page 0x84\n"); return 0; }
    IOHIDDeviceRef devs[8];
    CFSetGetValues(set, (const void **)devs);
    IOHIDDeviceRef dev = devs[0];
    printf("open+copy cpu %.0f us\n", cpu_us() - c0);

    // 收集 feature 报告 ID。
    CFArrayRef els = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
    int ids[256] = {0}, nids = 0, nfeat = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(els); i++) {
        IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(els, i);
        if (IOHIDElementGetType(e) != kIOHIDElementTypeFeature) continue;
        uint32_t up = IOHIDElementGetUsagePage(e);
        if (up != 0x84 && up != 0x85) continue;
        nfeat++;
        uint32_t rid = IOHIDElementGetReportID(e);
        if (!ids[rid]) { ids[rid] = 1; nids++; }
    }
    printf("elements=%ld feature(0x84/0x85)=%d reportIDs=%d\n", CFArrayGetCount(els), nfeat, nids);

    double *cpu = calloc(rounds, sizeof(double)), *wall = calloc(rounds, sizeof(double));
    uint8_t buf[64];
    int fails = 0;
    for (int r = 0; r < rounds; r++) {
        double cc = cpu_us(), ww = wall_us();
        for (int rid = 1; rid < 256; rid++) {
            if (!ids[rid]) continue;
            CFIndex len = sizeof(buf);
            if (IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, rid, buf, &len) != kIOReturnSuccess) fails++;
        }
        cpu[r] = cpu_us() - cc;
        wall[r] = wall_us() - ww;
    }
    qsort(cpu, rounds, sizeof(double), cmp);
    qsort(wall, rounds, sizeof(double), cmp);
    printf("full feature read (%d reports): cpu p50=%.0f us p90=%.0f us; wall p50=%.1f ms p90=%.1f ms; fails=%d\n",
           nids, cpu[rounds / 2], cpu[rounds * 9 / 10], wall[rounds / 2] / 1000, wall[rounds * 9 / 10] / 1000, fails);

    // 只读常用 9 个报告（与 CoreHID 探针的 core 组同口径：12 电量/剩余时间、22 状态位、49 输入电压、80 负载等）。
    int core[] = {12, 22, 49, 80, 6, 19, 20, 33, 38};
    for (int r = 0; r < rounds; r++) {
        double cc = cpu_us();
        for (int k = 0; k < 9; k++) {
            CFIndex len = sizeof(buf);
            IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, core[k], buf, &len);
        }
        cpu[r] = cpu_us() - cc;
    }
    qsort(cpu, rounds, sizeof(double), cmp);
    printf("core read (9 reports): cpu p50=%.0f us p90=%.0f us\n", cpu[rounds / 2], cpu[rounds * 9 / 10]);
    return 0;
}
