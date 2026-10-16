// gpu_struct.c - GPU 与加速器模块边界复核：只读结构比对（M5 Pro / M4 Pro）。
// 输出：
//   A. IOReport：GPU Stats 组全部通道（含状态名）、AGX 驱动的其他通道、媒体引擎/ANE 相关中断通道、
//      PMP(0) 中与 ANE/AVE/AGX 相关的带宽通道、Energy Model 通道名；
//   B. pmgr voltage-statesN 表（标出 Hz 单位的表及非零档数，用于与 GPUPH 状态数配对）；
//   C. IORegistry：AGX 加速器属性、PerformanceStatistics 全部键、user client 数；ANE 节点与电源状态；
//   D. SMC：Tg* / Ta* 键（类型、当前值）及 T* 前缀分布；
//   E. coalition：槽位 8 / 41 / 38 / 39 的非零个数与合计、按槽位 8 / 39 排序的前 5。
// 只读：SMC 只用 selector 2 的读命令（5/8/9），不打印序列号等设备标识。
// build: xcrun clang -O2 -o gpu_struct gpu_struct.c -lIOReport -framework IOKit -framework CoreFoundation
#include "ior.h"
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/sysctl.h>

CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);

static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

static int has_any(const char *s, const char **pats) {
    char low[256]; size_t i = 0;
    for (; s[i] && i < sizeof low - 1; i++) low[i] = (s[i] >= 'A' && s[i] <= 'Z') ? s[i] + 32 : s[i];
    low[i] = 0;
    for (int k = 0; pats[k]; k++) if (strstr(low, pats[k])) return 1;
    return 0;
}

// ---------- A. IOReport ----------
static void section_ioreport(void) {
    printf("\n## A. IOReport\n");
    double t0 = now_ms();
    CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
    double t1 = now_ms();
    if (!all) { printf("IOReportCopyAllChannels NULL\n"); return; }
    CFArrayRef arr = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    CFIndex n = arr ? CFArrayGetCount(arr) : 0;
    printf("all channels: %ld (copy %.1f ms)\n", (long)n, t1 - t0);
    static const char *irqPats[] = {"ave", "avd", "apr", "ane", "jpeg", "scaler", "msr", "prores", "agx", "gfx", "gpu", NULL};
    static const char *bwPats[] = {"ane", "ave", "avd", "apr", "agx", "gfx", "gpu", "msr", "jpg", "jpeg", NULL};
    char g[96], sg[128], nm[96], dv[128], un[32];
    printf("\n### A1. GPU Stats 组（计数类通道只按子组汇总；状态类通道的状态名取自一次采样）\n");
    {
        CFDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), NULL, 0, 0, 0);
        CFMutableDictionaryRef m = ch ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch) : NULL;
        CFMutableDictionaryRef sc = NULL;
        IOReportSubscriptionRef sub = m ? IOReportCreateSubscription(NULL, m, &sc, 0, NULL) : NULL;
        CFDictionaryRef smp = sub ? IOReportCreateSamples(sub, sc, NULL) : NULL;
        CFArrayRef sa = smp ? CFDictionaryGetValue(smp, CFSTR("IOReportChannels")) : NULL;
        char lastsg[128] = ""; int simpleCount = 0;
        for (CFIndex i = 0; sa && i < CFArrayGetCount(sa); i++) {
            CFDictionaryRef c = CFArrayGetValueAtIndex(sa, i);
            cs(IOReportChannelGetSubGroup(c), sg, sizeof sg); cs(IOReportChannelGetChannelName(c), nm, sizeof nm);
            cs(IOReportChannelGetUnitLabel(c), un, sizeof un);
            int fmt = IOReportChannelGetFormat(c);
            if (fmt == 1) {
                if (strcmp(sg, lastsg)) { if (simpleCount) printf("  (%d 个计数通道)\n", simpleCount); printf("%s | 计数: %s", sg, nm); simpleCount = 1; strcpy(lastsg, sg); }
                else { if (simpleCount < 4) printf(", %s", nm); simpleCount++; }
                continue;
            }
            if (simpleCount) { printf("  (%d 个计数通道)\n", simpleCount); simpleCount = 0; lastsg[0] = 0; }
            printf("%s | %s | fmt=%d | unit=%s", sg, nm, fmt, un);
            if (fmt == 2) {
                int k = IOReportStateGetCount(c);
                printf(" | states(%d):", k);
                for (int q = 0; q < k; q++) { char st[32]; cs(IOReportStateGetNameForIndex(c, q), st, sizeof st); printf(" %s", st); }
            } else if (fmt == 3) printf(" | buckets=%d", IOReportHistogramGetBucketCount(c));
            printf("\n");
        }
        if (simpleCount) printf("  (%d 个计数通道)\n", simpleCount);
        if (!sa) printf("GPU Stats subscription/sample failed\n");
    }
    printf("\n### A2. 其他组里 AGX 驱动的通道\n");
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i);
        cs(IOReportChannelGetGroup(c), g, sizeof g); cs(IOReportChannelGetDriverName(c), dv, sizeof dv);
        if (!strcmp(g, "GPU Stats") || strncmp(dv, "AGX", 3)) continue;
        cs(IOReportChannelGetSubGroup(c), sg, sizeof sg); cs(IOReportChannelGetChannelName(c), nm, sizeof nm);
        cs(IOReportChannelGetUnitLabel(c), un, sizeof un);
        static char lastKey[256]; static int rep;
        char key[256]; snprintf(key, sizeof key, "%s|%s|%d", g, strncmp(sg, "UT Engagement", 13) && strncmp(sg, "AVMR", 4) ? sg : "(per perf state)", IOReportChannelGetFormat(c));
        if (!strcmp(key, lastKey)) { rep++; continue; }
        if (rep) printf("    …另 %d 个同类通道\n", rep);
        rep = 0; strcpy(lastKey, key);
        printf("%s | %s | %s | fmt=%d | unit=%s\n", g, sg, nm, IOReportChannelGetFormat(c), un);
    }
    printf("\n### A3. 中断统计里与媒体引擎 / ANE / GPU 相关的通道\n");
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i);
        cs(IOReportChannelGetGroup(c), g, sizeof g);
        if (!strstr(g, "Interrupt")) continue;
        cs(IOReportChannelGetSubGroup(c), sg, sizeof sg); cs(IOReportChannelGetChannelName(c), nm, sizeof nm);
        if (!has_any(sg, irqPats) && !has_any(nm, irqPats)) continue;
        static char lastSg[128];
        if (!strcmp(sg, lastSg)) continue;
        strcpy(lastSg, sg);
        printf("%s | %s\n", g, sg);
    }
    printf("\n### A4. PMP 组里与 ANE / 媒体 / GPU 相关的通道\n");
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i);
        cs(IOReportChannelGetGroup(c), g, sizeof g);
        if (strncmp(g, "PMP", 3)) continue;
        cs(IOReportChannelGetSubGroup(c), sg, sizeof sg); cs(IOReportChannelGetChannelName(c), nm, sizeof nm);
        if (!has_any(nm, bwPats)) continue;
        cs(IOReportChannelGetUnitLabel(c), un, sizeof un);
        printf("%s | %s | %s | fmt=%d | unit=%s", g, sg, nm, IOReportChannelGetFormat(c), un);
        if (IOReportChannelGetFormat(c) == 2) printf(" | states=%d", IOReportStateGetCount(c));
        printf("\n");
    }
    printf("\n### A5. Energy Model 通道名\n");
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i);
        cs(IOReportChannelGetGroup(c), g, sizeof g);
        if (strcmp(g, "Energy Model")) continue;
        cs(IOReportChannelGetChannelName(c), nm, sizeof nm); cs(IOReportChannelGetDriverName(c), dv, sizeof dv);
        char *sp = strchr(dv, ' '); if (sp) *sp = 0;
        // 只列顶层与 ANE/AVE/GPU 相关的名字，避免几百行 CPU 子通道
        static const char *emPats[] = {"ane", "ave", "avd", "apr", "gpu", "afr", "msr", "isp", "disp", NULL};
        if (has_any(nm, emPats) || strncmp(dv, "AGX", 3) == 0) {
            cs(IOReportChannelGetUnitLabel(c), un, sizeof un);
            printf("%s [%s %s]\n", nm, dv, un);
        }
    }
    CFRelease(all);
}

// ---------- B. pmgr DVFS ----------
static void section_dvfs(void) {
    printf("\n## B. pmgr voltage-states（Hz 单位的表）\n");
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) != KERN_SUCCESS) return;
    io_object_t e;
    while ((e = IOIteratorNext(it))) {
        io_name_t name; IORegistryEntryGetName(e, name);
        if (strcmp(name, "pmgr")) { IOObjectRelease(e); continue; }
        CFMutableDictionaryRef props = NULL;
        IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0);
        CFIndex cnt = CFDictionaryGetCount(props);
        const void **ks = malloc(sizeof(void *) * cnt), **vs = malloc(sizeof(void *) * cnt);
        CFDictionaryGetKeysAndValues(props, ks, vs);
        for (int idx = 0; idx < 64; idx++) {
            for (int sram = 0; sram < 2; sram++) {
                char want[64]; snprintf(want, sizeof want, "voltage-states%d%s", idx, sram ? "-sram" : "");
                for (CFIndex i = 0; i < cnt; i++) {
                    char k[64]; cs(ks[i], k, sizeof k);
                    if (strcmp(k, want) || CFGetTypeID(vs[i]) != CFDataGetTypeID()) continue;
                    CFDataRef d = vs[i]; CFIndex len = CFDataGetLength(d); const uint32_t *p = (const uint32_t *)CFDataGetBytePtr(d);
                    int pairs = (int)(len / 8); uint32_t maxf = 0; int nz = 0;
                    for (int q = 0; q < pairs; q++) { if (p[2 * q] > maxf) maxf = p[2 * q]; if (p[2 * q]) nz++; }
                    if (maxf < 100000000u) continue;  // 只列 Hz 表（GPU 表单位是 Hz）
                    printf("%s: %d 档（非零 %d）:", k, pairs, nz);
                    for (int q = 0; q < pairs; q++) printf(" %u", p[2 * q] / 1000000u);
                    printf(" MHz\n");
                }
            }
        }
        static const char *extra[] = {"mgpu-count-per-die", NULL};
        for (int x = 0; extra[x]; x++) {
            CFStringRef kk = CFStringCreateWithCString(NULL, extra[x], kCFStringEncodingUTF8);
            CFTypeRef v = CFDictionaryGetValue(props, kk); CFRelease(kk);
            if (v && CFGetTypeID(v) == CFDataGetTypeID()) {
                printf("%s =", extra[x]);
                const uint8_t *b = CFDataGetBytePtr(v);
                for (CFIndex q = 0; q < CFDataGetLength(v); q++) printf(" %02x", b[q]);
                printf("\n");
            }
        }
        free(ks); free(vs); CFRelease(props); IOObjectRelease(e);
    }
    IOObjectRelease(it);
}

// ---------- C. IORegistry ----------
static void print_cf(CFTypeRef v) {
    if (!v) { printf("nil"); return; }
    CFTypeID t = CFGetTypeID(v);
    if (t == CFNumberGetTypeID()) { long long x = 0; CFNumberGetValue(v, kCFNumberSInt64Type, &x); printf("%lld", x); }
    else if (t == CFStringGetTypeID()) { char b[256]; cs(v, b, sizeof b); printf("\"%s\"", b); }
    else if (t == CFBooleanGetTypeID()) printf("%s", CFBooleanGetValue(v) ? "true" : "false");
    else if (t == CFDataGetTypeID()) printf("<data %ld>", (long)CFDataGetLength(v));
    else if (t == CFDictionaryGetTypeID()) printf("<dict %ld>", (long)CFDictionaryGetCount(v));
    else if (t == CFArrayGetTypeID()) printf("<array %ld>", (long)CFArrayGetCount(v));
    else printf("<?>");
}
static void dump_dict(CFDictionaryRef d, const char *indent) {
    CFIndex cnt = CFDictionaryGetCount(d);
    const void **ks = malloc(sizeof(void *) * cnt), **vs = malloc(sizeof(void *) * cnt);
    CFDictionaryGetKeysAndValues(d, ks, vs);
    // 按键名排序输出
    for (CFIndex i = 0; i < cnt; i++)
        for (CFIndex j = i + 1; j < cnt; j++)
            if (CFStringCompare(ks[i], ks[j], 0) == kCFCompareGreaterThan) { const void *t = ks[i]; ks[i] = ks[j]; ks[j] = t; t = vs[i]; vs[i] = vs[j]; vs[j] = t; }
    for (CFIndex i = 0; i < cnt; i++) {
        char k[128]; cs(ks[i], k, sizeof k);
        // 跳过可能含设备标识的键
        if (strstr(k, "UUID") || strstr(k, "serial") || strstr(k, "Serial")) continue;
        printf("%s%s = ", indent, k); print_cf(vs[i]); printf("\n");
    }
    free(ks); free(vs);
}
static void section_ioreg(void) {
    printf("\n## C. IORegistry\n");
    io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it);
    io_object_t acc;
    while ((acc = IOIteratorNext(it))) {
        io_name_t cls; IOObjectGetClass(acc, cls);
        printf("### IOAccelerator class=%s\n", cls);
        CFMutableDictionaryRef props = NULL;
        IORegistryEntryCreateCFProperties(acc, &props, kCFAllocatorDefault, 0);
        static const char *keys[] = {"gpu-core-count", "model", "AGXParameterBufferMaxSize", "IOGLBundleName", "MetalPluginName", "GPUConfigurationVariable", NULL};
        for (int k = 0; keys[k]; k++) {
            CFStringRef kk = CFStringCreateWithCString(NULL, keys[k], kCFStringEncodingUTF8);
            CFTypeRef v = CFDictionaryGetValue(props, kk); CFRelease(kk);
            printf("%s = ", keys[k]); print_cf(v); printf("\n");
            if (v && CFGetTypeID(v) == CFDictionaryGetTypeID()) dump_dict(v, "    ");
        }
        CFTypeRef ps = CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
        if (ps && CFGetTypeID(ps) == CFDictionaryGetTypeID()) { printf("PerformanceStatistics:\n"); dump_dict(ps, "    "); }
        // 顶层键名（不含值）
        printf("top-level keys:");
        CFIndex cnt = CFDictionaryGetCount(props);
        const void **ks = malloc(sizeof(void *) * cnt);
        CFDictionaryGetKeysAndValues(props, ks, NULL);
        for (CFIndex i = 0; i < cnt; i++) { char k[128]; cs(ks[i], k, sizeof k); printf(" %s", k); }
        printf("\n"); free(ks); CFRelease(props);
        // user client
        io_iterator_t kids; int nuc = 0, nAppUsage = 0;
        if (IORegistryEntryGetChildIterator(acc, kIOServicePlane, &kids) == KERN_SUCCESS) {
            io_object_t c;
            while ((c = IOIteratorNext(kids))) {
                io_name_t kc; IOObjectGetClass(c, kc);
                if (strstr(kc, "UserClient")) {
                    nuc++;
                    CFTypeRef au = IORegistryEntryCreateCFProperty(c, CFSTR("AppUsage"), kCFAllocatorDefault, 0);
                    if (au) { nAppUsage++; CFRelease(au); }
                }
                IOObjectRelease(c);
            }
            IOObjectRelease(kids);
        }
        printf("user clients: %d (with AppUsage: %d)\n", nuc, nAppUsage);
        IOObjectRelease(acc);
    }
    IOObjectRelease(it);

    static const char *aneClasses[] = {"H11ANEIn", "H11ANE", "ANEExclaveProxy", "ANEClientHints", "AppleH11ANEInterface", NULL};
    for (int a = 0; aneClasses[a]; a++) {
        io_iterator_t ai;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(aneClasses[a]), &ai) != KERN_SUCCESS) continue;
        io_object_t e; int found = 0;
        while ((e = IOIteratorNext(ai))) {
            io_name_t nm, cls; IORegistryEntryGetName(e, nm); IOObjectGetClass(e, cls);
            printf("### ANE 节点 match=%s class=%s name=%s\n", aneClasses[a], cls, nm);
            CFMutableDictionaryRef props = NULL;
            IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0);
            if (props) {
                CFTypeRef pm = CFDictionaryGetValue(props, CFSTR("IOPowerManagement"));
                if (pm && CFGetTypeID(pm) == CFDictionaryGetTypeID()) { printf("IOPowerManagement:\n"); dump_dict(pm, "    "); }
                printf("keys:");
                CFIndex cnt = CFDictionaryGetCount(props);
                const void **ks = malloc(sizeof(void *) * cnt);
                CFDictionaryGetKeysAndValues(props, ks, NULL);
                for (CFIndex i = 0; i < cnt; i++) { char k[128]; cs(ks[i], k, sizeof k); printf(" %s", k); }
                printf("\n"); free(ks);
                static const char *aneKeys[] = {"ane_power_state", "ANEDevicePropertyTypeANEArchitectureTypeStr", "ANEDevicePropertyNumANECores", "ANEDevicePropertyNumANEs", "DeviceProperties", NULL};
                for (int k = 0; aneKeys[k]; k++) {
                    CFStringRef kk = CFStringCreateWithCString(NULL, aneKeys[k], kCFStringEncodingUTF8);
                    CFTypeRef v = CFDictionaryGetValue(props, kk); CFRelease(kk);
                    if (!v) continue;
                    printf("%s = ", aneKeys[k]); print_cf(v); printf("\n");
                    if (CFGetTypeID(v) == CFDictionaryGetTypeID()) dump_dict(v, "    ");
                }
                CFRelease(props);
            }
            found++; IOObjectRelease(e);
            if (found >= 3) break;
        }
        IOObjectRelease(ai);
    }
}

// ---------- D. SMC ----------
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t smc;
static void s4(uint32_t k, char *o) { o[0] = k >> 24; o[1] = k >> 16; o[2] = k >> 8; o[3] = k; o[4] = 0; }
static uint32_t k4(const char *s) { return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3]; }
static int smc_call(SMCParam *in, SMCParam *out) {
    // 只允许读命令：5 读值、8 按序号取键、9 取 key-info
    if (in->data8 != 5 && in->data8 != 8 && in->data8 != 9) return -1;
    size_t sz = sizeof(SMCParam);
    return IOConnectCallStructMethod(smc, 2, in, sizeof(SMCParam), out, &sz) == KERN_SUCCESS ? 0 : -1;
}
static void section_smc(void) {
    printf("\n## D. SMC Tg* / Ta*\n");
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!s || IOServiceOpen(s, mach_task_self(), 0, &smc) != KERN_SUCCESS) { printf("SMC open failed\n"); return; }
    IOObjectRelease(s);
    SMCParam in = {0}, out = {0};
    in.key = k4("#KEY"); in.keyInfo.dataSize = 4; in.data8 = 5;
    smc_call(&in, &out);
    int cnt = (int)((uint32_t)out.bytes[0] << 24 | out.bytes[1] << 16 | out.bytes[2] << 8 | out.bytes[3]);
    int prefix[128][128]; memset(prefix, 0, sizeof prefix);
    int ntg = 0, nta = 0;
    for (int i = 0; i < cnt; i++) {
        SMCParam a = {0}, b = {0}; a.data8 = 8; a.data32 = i;
        if (smc_call(&a, &b)) continue;
        char nm[5]; s4(b.key, nm);
        if (nm[0] != 'T') continue;
        prefix[(int)nm[1] & 127][0]++;
        if (!(nm[1] == 'g' || nm[1] == 'a')) continue;
        SMCParam c = {0}, d = {0}; c.key = b.key; c.data8 = 9;
        if (smc_call(&c, &d) || d.result) continue;
        char t[5]; s4(d.keyInfo.dataType, t);
        SMCParam e = {0}, f = {0}; e.key = b.key; e.keyInfo.dataSize = d.keyInfo.dataSize; e.data8 = 5;
        printf("%s %s size=%u attr=0x%02x", nm, t, d.keyInfo.dataSize, d.keyInfo.dataAttributes);
        if (!smc_call(&e, &f) && !f.result && !strcmp(t, "flt ") && d.keyInfo.dataSize == 4) { float v; memcpy(&v, f.bytes, 4); printf(" = %.2f", v); }
        else printf(" = (result %u)", f.result);
        printf("\n");
        if (nm[1] == 'g') ntg++; else nta++;
    }
    printf("Tg*=%d Ta*=%d; T* 第二字母分布:", ntg, nta);
    for (int c = 0; c < 128; c++) if (prefix[c][0]) printf(" T%c=%d", c, prefix[c][0]);
    printf("\n");
    IOServiceClose(smc);
}

// ---------- E. coalition ----------
typedef struct { uint64_t id; uint32_t type; uint32_t tasks; } coal_entry;
typedef int (*coal_list_fn)(int, int, void *, int);
typedef int (*coal_usage_fn)(uint64_t, void *, size_t);
typedef int (*coal_pids_fn)(uint64_t, void *, size_t *);
typedef struct { uint64_t cid; uint64_t v; char name[64]; } topent;
static void top_insert(topent *t, int n, uint64_t cid, uint64_t v) {
    if (v <= t[n - 1].v) return;
    int i = n - 1;
    while (i > 0 && t[i - 1].v < v) { t[i] = t[i - 1]; i--; }
    t[i].cid = cid; t[i].v = v; t[i].name[0] = 0;
}
static void section_coal(void) {
    printf("\n## E. coalition 槽位 8 / 41 / 38 / 39\n");
    coal_list_fn cl = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
    coal_usage_fn cu = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage");
    coal_pids_fn cp = dlsym(RTLD_DEFAULT, "coalition_info_pid_list");
    if (!cl || !cu || !cp) { printf("coalition symbols missing\n"); return; }
    int need = cl(2, 0, NULL, 0);
    coal_entry *ents = calloc(need / sizeof(coal_entry) + 64, sizeof(coal_entry));
    int got = cl(2, 0, ents, need + 64 * (int)sizeof(coal_entry));
    int ne = got / (int)sizeof(coal_entry);
    static const int slots[] = {8, 41, 38, 39};
    uint64_t sum[4] = {0}; int nz[4] = {0}; int live = 0;
    topent tg[5] = {{0}}, ta[5] = {{0}};
    double t0 = now_ms();
    for (int i = 0; i < ne; i++) {
        if (ents[i].tasks == 0) continue;
        uint64_t u[64]; memset(u, 0, sizeof u);
        if (cu(ents[i].id, u, sizeof u)) continue;
        live++;
        for (int k = 0; k < 4; k++) { sum[k] += u[slots[k]]; if (u[slots[k]]) nz[k]++; }
        top_insert(tg, 5, ents[i].id, u[8]);
        top_insert(ta, 5, ents[i].id, u[39]);
    }
    double t1 = now_ms();
    printf("live coalitions: %d (scan %.2f ms)\n", live, t1 - t0);
    for (int k = 0; k < 4; k++) printf("slot %d: nonzero=%d sum=%llu\n", slots[k], nz[k], (unsigned long long)sum[k]);
    topent *lists[2] = {tg, ta}; const char *lab[2] = {"slot 8 gpu_time(ns)", "slot 39 ane_energy(nJ)"};
    for (int L = 0; L < 2; L++) {
        printf("top by %s:\n", lab[L]);
        for (int i = 0; i < 5 && lists[L][i].v; i++) {
            pid_t pids[64]; size_t sz = sizeof pids;
            char name[64] = "?";
            if (cp(lists[L][i].cid, pids, &sz) == 0) for (size_t q = 0; q < sz / sizeof(pid_t) && q < 64; q++) if (proc_name(pids[q], name, sizeof name) > 0) break;
            uint64_t u[64]; memset(u, 0, sizeof u); cu(lists[L][i].cid, u, sizeof u);
            printf("  %-28s gpu_time=%.1fs gpu_E=%.1fJ ane_t=%.1fs(tick) ane_E=%.2fJ members=%zu\n", name, u[8] / 1e9, u[41] / 1e9,
                   u[38] * 125.0 / 3 / 1e9, u[39] / 1e9, sz / sizeof(pid_t));
        }
    }
    free(ents);
}

int main(void) {
    char model[64] = ""; size_t len = sizeof model;
    sysctlbyname("machdep.cpu.brand_string", model, &len, NULL, 0);
    char build[32] = ""; len = sizeof build; sysctlbyname("kern.osversion", build, &len, NULL, 0);
    printf("# gpu_struct: %s, build %s\n", model, build);
    section_ioreport();
    section_dvfs();
    section_ioreg();
    section_smc();
    section_coal();
    return 0;
}
