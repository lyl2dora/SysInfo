// costbench_gpu.c - 真实节奏（每 1 s 醒来一次，每次只做一项）下 GPU 模块各读取项的线程 CPU 开销：
//   A) GPUPH 单通道订阅：采样 + 差分 + 读状态驻留；
//   B) AGX「GPU Energy」单通道订阅：采样 + 差分；
//   C) A 与 B 合并成一个订阅（两通道）；
//   D) 全部 Tg* 键（flt）各读一次；
//   E) IORegistry：H11ANEIn 的 IOPowerManagement + AGX PerformanceStatistics；
//   F) 媒体引擎中断（ave0/avd0/apr0 一级中断计数）订阅：采样 + 差分。
// 只读：SMC 只用 selector 2 的读命令（5/8/9）。
// build: xcrun clang -O2 -o costbench_gpu costbench_gpu.c -lIOReport -framework IOKit -framework CoreFoundation
// usage: costbench_gpu <rounds>
#include "ior.h"
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double tc(void) { struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts); return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6; }
static int cmpd(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }

typedef int (*filt)(CFDictionaryRef c);
static int f_gpuph(CFDictionaryRef c) { char n[64]; cs(IOReportChannelGetChannelName(c), n, 64); return !strcmp(n, "GPUPH"); }
static int f_energy(CFDictionaryRef c) { char n[64], d[64]; cs(IOReportChannelGetChannelName(c), n, 64); cs(IOReportChannelGetDriverName(c), d, 64); return !strcmp(n, "GPU Energy") && !strncmp(d, "AGX", 3); }
static int f_both(CFDictionaryRef c) { return f_gpuph(c) || f_energy(c); }
static int f_irq(CFDictionaryRef c) {
    char g[96], sg[64], n[96]; cs(IOReportChannelGetGroup(c), g, 96); cs(IOReportChannelGetSubGroup(c), sg, 64); cs(IOReportChannelGetChannelName(c), n, 96);
    if (!strstr(g, "Interrupt") || !strstr(n, "First Level Interrupt Handler Count")) return 0;
    return !strncmp(sg, "ave0 ", 5) || !strncmp(sg, "avd0 ", 5) || !strncmp(sg, "apr0 ", 5);
}
typedef struct { IOReportSubscriptionRef sub; CFMutableDictionaryRef subbed; CFDictionaryRef prev; } Sub;
static Sub mk(const char *group, filt f) {
    Sub s = {0};
    CFDictionaryRef ch = group ? IOReportCopyChannelsInGroup(CFStringCreateWithCString(NULL, group, kCFStringEncodingUTF8), NULL, 0, 0, 0)
                               : IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"), NULL, 0, 0, 0);
    if (!ch) return s;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, ch);
    CFArrayRef arr = CFDictionaryGetValue(m, CFSTR("IOReportChannels"));
    CFMutableArrayRef keep = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) if (f(CFArrayGetValueAtIndex(arr, i))) CFArrayAppendValue(keep, CFArrayGetValueAtIndex(arr, i));
    CFDictionarySetValue(m, CFSTR("IOReportChannels"), keep);
    s.sub = IOReportCreateSubscription(NULL, m, &s.subbed, 0, NULL);
    if (s.sub) s.prev = IOReportCreateSamples(s.sub, s.subbed, NULL);
    printf("subscription %s: %ld channels, %s\n", group ? group : "Interrupt Statistics (by index)", (long)CFArrayGetCount(keep), s.sub ? "ok" : "FAILED");
    return s;
}
static volatile double sink;
static void step(Sub *s) {
    if (!s->sub) return;
    CFDictionaryRef cur = IOReportCreateSamples(s->sub, s->subbed, NULL);
    CFDictionaryRef d = IOReportCreateSamplesDelta(s->prev, cur, NULL);
    CFArrayRef a = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(a, i);
        if (IOReportChannelGetFormat(c) == 2) { int k = IOReportStateGetCount(c); for (int q = 0; q < k; q++) sink += IOReportStateGetResidency(c, q); }
        else sink += IOReportSimpleGetIntegerValue(c, 0);
    }
    CFRelease(d); CFRelease(s->prev); s->prev = cur;
}

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t smc;
static int smc_call(SMCParam *in, SMCParam *out) {
    if (in->data8 != 5 && in->data8 != 8 && in->data8 != 9) return -1;
    size_t sz = sizeof(SMCParam);
    return IOConnectCallStructMethod(smc, 2, in, sizeof(SMCParam), out, &sz) == KERN_SUCCESS ? 0 : -1;
}

int main(int argc, char **argv) {
    int N = argc > 1 ? atoi(argv[1]) : 30; if (N > 120) N = 120;
    Sub a = mk("GPU Stats", f_gpuph), b = mk("Energy Model", f_energy);
    // C：两个组合并成一个订阅
    Sub c = {0};
    {
        CFDictionaryRef g1 = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), NULL, 0, 0, 0), g2 = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
        CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, g1);
        IOReportMergeChannels(m, g2, NULL);
        CFArrayRef arr = CFDictionaryGetValue(m, CFSTR("IOReportChannels"));
        CFMutableArrayRef keep = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) if (f_both(CFArrayGetValueAtIndex(arr, i))) CFArrayAppendValue(keep, CFArrayGetValueAtIndex(arr, i));
        CFDictionarySetValue(m, CFSTR("IOReportChannels"), keep);
        c.sub = IOReportCreateSubscription(NULL, m, &c.subbed, 0, NULL);
        if (c.sub) c.prev = IOReportCreateSamples(c.sub, c.subbed, NULL);
        printf("subscription merged: %ld channels, %s\n", (long)CFArrayGetCount(keep), c.sub ? "ok" : "FAILED");
    }
    Sub f = mk(NULL, f_irq);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    IOServiceOpen(s, mach_task_self(), 0, &smc);
    uint32_t tg[64]; int ntg = 0;
    {
        SMCParam in = {0}, out = {0}; in.key = '#KEY'; in.keyInfo.dataSize = 4; in.data8 = 5; smc_call(&in, &out);
        int cnt = (int)((uint32_t)out.bytes[0] << 24 | out.bytes[1] << 16 | out.bytes[2] << 8 | out.bytes[3]);
        for (int i = 0; i < cnt && ntg < 64; i++) {
            SMCParam x = {0}, y = {0}; x.data8 = 8; x.data32 = i;
            if (smc_call(&x, &y)) continue;
            if ((y.key >> 24) == 'T' && ((y.key >> 16) & 0xff) == 'g') tg[ntg++] = y.key;
        }
        printf("Tg keys: %d\n", ntg);
    }
    io_service_t ane = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn"));
    io_service_t agx = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    double A[120], B[120], C[120], D[120], E[120], F[120];
    for (int n = 0; n < N; n++) {
        double t0, t1;
        sleep(1); t0 = tc(); step(&a); t1 = tc(); A[n] = t1 - t0;
        sleep(1); t0 = tc(); step(&b); t1 = tc(); B[n] = t1 - t0;
        sleep(1); t0 = tc(); step(&c); t1 = tc(); C[n] = t1 - t0;
        sleep(1); t0 = tc();
        for (int i = 0; i < ntg; i++) { SMCParam x = {0}, y = {0}; x.key = tg[i]; x.keyInfo.dataSize = 4; x.data8 = 5; if (!smc_call(&x, &y)) { float v; memcpy(&v, y.bytes, 4); sink += v; } }
        t1 = tc(); D[n] = t1 - t0;
        sleep(1); t0 = tc();
        CFTypeRef p1 = IORegistryEntryCreateCFProperty(ane, CFSTR("IOPowerManagement"), NULL, 0); if (p1) CFRelease(p1);
        CFTypeRef p2 = IORegistryEntryCreateCFProperty(agx, CFSTR("PerformanceStatistics"), NULL, 0); if (p2) CFRelease(p2);
        t1 = tc(); E[n] = t1 - t0;
        sleep(1); t0 = tc(); step(&f); t1 = tc(); F[n] = t1 - t0;
    }
    double *all[6] = {A, B, C, D, E, F}; const char *lab[6] = {"A GPUPH 单通道", "B GPU Energy 单通道", "C GPUPH+GPU Energy 合并", "D Tg 全部键", "E ANE 电源 + PerfStats", "F 媒体中断"};
    printf("真实节奏线程 CPU（ms/次，%d 轮）：\n", N);
    for (int k = 0; k < 6; k++) { qsort(all[k], N, 8, cmpd); printf("  %s：中位 %.3f，p90 %.3f\n", lab[k], all[k][N / 2], all[k][N * 9 / 10]); }
    return 0;
}
