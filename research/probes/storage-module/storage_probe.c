// 存储模块边界探针（2026-10-16）。只读：IORegistry、IOBlockStorageDriver Statistics、
// NVMe SMART（SMARTReadData / GetIdentifyData / GetLogPage 0x02），以及私有 IOReport「NVMe」组的电源状态驻留。
// 不打印序列号、UUID 等设备唯一标识。
//
// 用法：
//   storage_probe list                 物理盘清单 + SMART 全字段 + 单次耗时
//   storage_probe cost <n>             SMART 读取开销：每次重建 plugin vs 常驻 plugin（各 n 次）
//   storage_probe pstate <秒> <间隔>   NVMe 电源状态驻留；间隔 > 0 时窗口内按该间隔读全部盘的 SMART
// 编译：xcrun clang -O2 -framework IOKit -framework CoreFoundation -lIOReport storage_probe.c -o storage_probe
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOBlockStorageDevice.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int (^ioreportiterateblock)(CFDictionaryRef);
extern void IOReportIterate(CFDictionaryRef, ioreportiterateblock);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef), IOReportChannelGetDriverName(CFDictionaryRef);
extern int IOReportChannelGetFormat(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
extern uint64_t IOReportChannelGetChannelID(CFDictionaryRef);

static double now_ms(clockid_t c) { return clock_gettime_nsec_np(c) / 1e6; }
static void cfstr(CFTypeRef v, char *buf, size_t n) {
    buf[0] = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, buf, n, kCFStringEncodingUTF8);
}
static long long cfnum(CFTypeRef v) {
    long long x = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongLongType, &x);
    return x;
}
static long double u128(const uint64_t v[2]) { return (long double)v[0] + (long double)v[1] * 18446744073709551616.0L; }

// 物理盘：IOBlockStorageDevice，Physical Interconnect 不是 Virtual Interface，位置不是 File。
static int is_physical(io_object_t dev, char *ic, char *loc) {
    CFDictionaryRef pc = IORegistryEntryCreateCFProperty(dev, CFSTR(kIOPropertyProtocolCharacteristicsKey), kCFAllocatorDefault, 0);
    ic[0] = loc[0] = 0;
    if (pc) {
        cfstr(CFDictionaryGetValue(pc, CFSTR(kIOPropertyPhysicalInterconnectTypeKey)), ic, 64);
        cfstr(CFDictionaryGetValue(pc, CFSTR(kIOPropertyPhysicalInterconnectLocationKey)), loc, 64);
        CFRelease(pc);
    }
    if (!strcmp(ic, "Virtual Interface") || !strcmp(loc, "File") || ic[0] == 0) return 0;
    return 1;
}

// 设备下的整盘 IOMedia（深度优先找 Whole=Yes 的第一个）及其驱动 Statistics。
static io_object_t whole_media(io_object_t dev) {
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(dev, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return 0;
    io_object_t o, found = 0;
    while ((o = IOIteratorNext(it))) {
        if (!found && IOObjectConformsTo(o, kIOMediaClass)) {
            CFTypeRef w = IORegistryEntryCreateCFProperty(o, CFSTR(kIOMediaWholeKey), kCFAllocatorDefault, 0);
            if (w == kCFBooleanTrue) { found = o; if (w) CFRelease(w); continue; }
            if (w) CFRelease(w);
        }
        IOObjectRelease(o);
    }
    IOObjectRelease(it);
    return found;
}

static void print_stats(io_object_t dev) {
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(dev, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return;
    io_object_t o;
    while ((o = IOIteratorNext(it))) {
        if (IOObjectConformsTo(o, kIOBlockStorageDriverClass)) {
            CFDictionaryRef st = IORegistryEntryCreateCFProperty(o, CFSTR(kIOBlockStorageDriverStatisticsKey), kCFAllocatorDefault, 0);
            if (st) {
                printf("    stats: bytesR=%lld bytesW=%lld opsR=%lld opsW=%lld timeR=%lldns timeW=%lldns errR=%lld errW=%lld retR=%lld retW=%lld\n",
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsReadsKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsWritesKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsTotalReadTimeKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsTotalWriteTimeKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsReadErrorsKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsWriteErrorsKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsReadRetriesKey))),
                       cfnum(CFDictionaryGetValue(st, CFSTR(kIOBlockStorageDriverStatisticsWriteRetriesKey))));
                CFRelease(st);
            }
            IOObjectRelease(o);
            break;
        }
        IOObjectRelease(o);
    }
    IOObjectRelease(it);
}

// 整盘下的分区内容（Apple_RAID / Apple_APFS …），以及 RAID 成员状态。
static void print_children(io_object_t media) {
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(media, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return;
    io_object_t o;
    while ((o = IOIteratorNext(it))) {
        io_name_t cls; IOObjectGetClass(o, cls);
        if (IOObjectConformsTo(o, kIOMediaClass)) {
            char content[128], bsd[64];
            cfstr(IORegistryEntryCreateCFProperty(o, CFSTR(kIOMediaContentKey), kCFAllocatorDefault, 0), content, sizeof content);
            cfstr(IORegistryEntryCreateCFProperty(o, CFSTR(kIOBSDNameKey), kCFAllocatorDefault, 0), bsd, sizeof bsd);
            CFTypeRef leaf = IORegistryEntryCreateCFProperty(o, CFSTR(kIOMediaLeafKey), kCFAllocatorDefault, 0);
            long long size = cfnum(IORegistryEntryCreateCFProperty(o, CFSTR(kIOMediaSizeKey), kCFAllocatorDefault, 0));
            printf("      media %-10s %-14s content=%s size=%.1fGB leaf=%d\n", bsd, cls, content, size / 1e9, leaf == kCFBooleanTrue);
        } else if (strstr(cls, "RAID") || strstr(cls, "APFS")) {
            char st[64] = "", lvl[64] = "", mst[64] = "";
            cfstr(IORegistryEntryCreateCFProperty(o, CFSTR("AppleRAID-SetStatus"), kCFAllocatorDefault, 0), st, sizeof st);
            cfstr(IORegistryEntryCreateCFProperty(o, CFSTR("AppleRAID-LevelName"), kCFAllocatorDefault, 0), lvl, sizeof lvl);
            cfstr(IORegistryEntryCreateCFProperty(o, CFSTR("AppleRAID-MemberStatus"), kCFAllocatorDefault, 0), mst, sizeof mst);
            printf("      node %s set=%s level=%s member=%s\n", cls, st, lvl, mst);
        }
        IOObjectRelease(o);
    }
    IOObjectRelease(it);
}

typedef struct { IOCFPlugInInterface **plugin; IONVMeSMARTInterface **smart; } smart_handle;

static int smart_open(io_object_t dev, smart_handle *h) {
    SInt32 score;
    h->plugin = NULL; h->smart = NULL;
    if (IOCreatePlugInInterfaceForService(dev, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &h->plugin, &score) != KERN_SUCCESS || !h->plugin) return 0;
    if ((*h->plugin)->QueryInterface(h->plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&h->smart) != S_OK || !h->smart) {
        IODestroyPlugInInterface(h->plugin); h->plugin = NULL; return 0;
    }
    return 1;
}
static void smart_close(smart_handle *h) {
    if (h->smart) (*h->smart)->Release(h->smart);
    if (h->plugin) IODestroyPlugInInterface(h->plugin);
    h->smart = NULL; h->plugin = NULL;
}

static void print_smart(smart_handle *h) {
    NVMeSMARTData d; memset(&d, 0, sizeof d);
    double w0 = now_ms(CLOCK_UPTIME_RAW), c0 = now_ms(CLOCK_THREAD_CPUTIME_ID);
    IOReturn r = (*h->smart)->SMARTReadData(h->smart, &d);
    printf("    SMARTReadData r=0x%x wall=%.2fms cpu=%.3fms\n", r, now_ms(CLOCK_UPTIME_RAW) - w0, now_ms(CLOCK_THREAD_CPUTIME_ID) - c0);
    if (r != kIOReturnSuccess) return;
    const uint8_t *b = (const uint8_t *)&d;
    printf("    critical_warning=0x%02x composite=%dC spare=%u%% spare_thresh=%u%% pct_used=%u%% endurance_group_cw=0x%02x\n",
           d.CRITICAL_WARNING, (int)d.TEMPERATURE - 273, d.AVAILABLE_SPARE, d.AVAILABLE_SPARE_THRESHOLD, d.PERCENTAGE_USED, b[6]);
    printf("    units_read=%.0Lf (%.2Lf TB) units_written=%.0Lf (%.2Lf TB) host_rd_cmds=%.0Lf host_wr_cmds=%.0Lf\n",
           u128(d.DATA_UNITS_READ), u128(d.DATA_UNITS_READ) * 512000.0L / 1e12L, u128(d.DATA_UNITS_WRITTEN), u128(d.DATA_UNITS_WRITTEN) * 512000.0L / 1e12L,
           u128(d.HOST_READ_COMMANDS), u128(d.HOST_WRITE_COMMANDS));
    printf("    busy_min=%.0Lf power_cycles=%.0Lf poh=%.0Lf unsafe=%.0Lf media_err=%.0Lf err_log=%.0Lf\n",
           u128(d.CONTROLLER_BUSY_TIME), u128(d.POWER_CYCLES), u128(d.POWER_ON_HOURS), u128(d.UNSAFE_SHUTDOWNS), u128(d.MEDIA_ERRORS), u128(d.NUM_ERROR_INFO_LOG_ENTRIES));
    uint32_t wtt, ctt; memcpy(&wtt, b + 192, 4); memcpy(&ctt, b + 196, 4);
    printf("    warn_temp_min=%u crit_temp_min=%u sensors:", wtt, ctt);
    for (int i = 0; i < 8; i++) { uint16_t ts; memcpy(&ts, b + 200 + 2 * i, 2); printf(" %d", ts ? (int)ts - 273 : -999); }
    uint32_t tmt[4]; memcpy(tmt, b + 216, 16);
    printf("  tmt1_count=%u tmt2_count=%u tmt1_s=%u tmt2_s=%u\n", tmt[0], tmt[1], tmt[2], tmt[3]);
    static NVMeIdentifyControllerStruct idc; memset(&idc, 0, sizeof idc);
    w0 = now_ms(CLOCK_UPTIME_RAW);
    r = (*h->smart)->GetIdentifyData(h->smart, &idc, 0);
    if (r == kIOReturnSuccess) {
        const uint8_t *ib = (const uint8_t *)&idc; uint16_t wct, cct; memcpy(&wct, ib + 266, 2); memcpy(&cct, ib + 268, 2);
        char mn[41], fr[9]; memcpy(mn, idc.MODEL_NUMBER, 40); mn[40] = 0; memcpy(fr, idc.FW_REVISION, 8); fr[8] = 0;
        printf("    identify %.2fms vid=0x%04x mn='%s' fw='%s' wctemp=%d cctemp=%d nn=%u lpa=0x%x npss=%u apsta=%u ver=0x%x\n",
               now_ms(CLOCK_UPTIME_RAW) - w0, idc.PCI_VID, mn, fr, wct ? (int)wct - 273 : -999, cct ? (int)cct - 273 : -999,
               idc.NUM_OF_NAMESPACES, idc.LOG_PAGE_ATTR, ib[263], ib[265], *(uint32_t *)(ib + 80));
    } else printf("    identify r=0x%x\n", r);
}

static int collect(io_object_t devs[], int max) {
    io_iterator_t it; int n = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDeviceClass), &it);
    io_object_t dev; char ic[64], loc[64];
    while ((dev = IOIteratorNext(it))) {
        if (n < max && is_physical(dev, ic, loc)) devs[n++] = dev; else IOObjectRelease(dev);
    }
    IOObjectRelease(it);
    return n;
}

static void cmd_list(void) {
    io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDeviceClass), &it);
    io_object_t dev;
    while ((dev = IOIteratorNext(it))) {
        io_name_t cls; IOObjectGetClass(dev, cls);
        char ic[64], loc[64], model[128] = "", medium[64] = "", rev[64] = "";
        int phys = is_physical(dev, ic, loc);
        CFDictionaryRef dc = IORegistryEntryCreateCFProperty(dev, CFSTR(kIOPropertyDeviceCharacteristicsKey), kCFAllocatorDefault, 0);
        if (dc) {
            cfstr(CFDictionaryGetValue(dc, CFSTR(kIOPropertyProductNameKey)), model, sizeof model);
            cfstr(CFDictionaryGetValue(dc, CFSTR(kIOPropertyMediumTypeKey)), medium, sizeof medium);
            cfstr(CFDictionaryGetValue(dc, CFSTR(kIOPropertyProductRevisionLevelKey)), rev, sizeof rev);
            CFRelease(dc);
        }
        CFTypeRef cap = IORegistryEntryCreateCFProperty(dev, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFAllocatorDefault, 0);
        printf("\n== %s physical=%d interconnect='%s' location='%s' model='%s' medium='%s' rev='%s' smart=%d\n",
               cls, phys, ic, loc, model, medium, rev, cap == kCFBooleanTrue);
        if (cap) CFRelease(cap);
        if (!phys) { IOObjectRelease(dev); continue; }
        io_object_t media = whole_media(dev);
        if (media) {
            char bsd[64]; cfstr(IORegistryEntryCreateCFProperty(media, CFSTR(kIOBSDNameKey), kCFAllocatorDefault, 0), bsd, sizeof bsd);
            long long size = cfnum(IORegistryEntryCreateCFProperty(media, CFSTR(kIOMediaSizeKey), kCFAllocatorDefault, 0));
            long long bs = cfnum(IORegistryEntryCreateCFProperty(media, CFSTR(kIOMediaPreferredBlockSizeKey), kCFAllocatorDefault, 0));
            CFTypeRef rem = IORegistryEntryCreateCFProperty(media, CFSTR(kIOMediaRemovableKey), kCFAllocatorDefault, 0);
            printf("    whole=%s size=%.1fGB block=%lld removable=%d\n", bsd, size / 1e9, bs, rem == kCFBooleanTrue);
            print_children(media);
            IOObjectRelease(media);
        }
        print_stats(dev);
        if (cap == kCFBooleanTrue) {
            smart_handle h;
            double w0 = now_ms(CLOCK_UPTIME_RAW);
            if (smart_open(dev, &h)) {
                printf("    open %.2fms\n", now_ms(CLOCK_UPTIME_RAW) - w0);
                print_smart(&h);
                smart_close(&h);
            } else printf("    open failed\n");
        }
        IOObjectRelease(dev);
    }
    IOObjectRelease(it);
}

static void cmd_cost(int n) {
    io_object_t devs[32]; int count = collect(devs, 32);
    for (int i = 0; i < count; i++) {
        CFTypeRef cap = IORegistryEntryCreateCFProperty(devs[i], CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFAllocatorDefault, 0);
        if (cap != kCFBooleanTrue) { if (cap) CFRelease(cap); continue; }
        CFRelease(cap);
        char ic[64], loc[64]; is_physical(devs[i], ic, loc);
        double wall = 0, cpu = 0, wmax = 0;
        for (int k = 0; k < n; k++) {
            double w0 = now_ms(CLOCK_UPTIME_RAW), c0 = now_ms(CLOCK_THREAD_CPUTIME_ID);
            smart_handle h; NVMeSMARTData d;
            if (smart_open(devs[i], &h)) { (*h.smart)->SMARTReadData(h.smart, &d); smart_close(&h); }
            double w = now_ms(CLOCK_UPTIME_RAW) - w0; wall += w; if (w > wmax) wmax = w;
            cpu += now_ms(CLOCK_THREAD_CPUTIME_ID) - c0;
            usleep(200000);
        }
        printf("disk#%d %-8s reopen:   wall avg=%.2fms max=%.2fms cpu avg=%.3fms\n", i, loc, wall / n, wmax, cpu / n);
        smart_handle h;
        if (!smart_open(devs[i], &h)) continue;
        wall = cpu = wmax = 0;
        for (int k = 0; k < n; k++) {
            NVMeSMARTData d;
            double w0 = now_ms(CLOCK_UPTIME_RAW), c0 = now_ms(CLOCK_THREAD_CPUTIME_ID);
            (*h.smart)->SMARTReadData(h.smart, &d);
            double w = now_ms(CLOCK_UPTIME_RAW) - w0; wall += w; if (w > wmax) wmax = w;
            cpu += now_ms(CLOCK_THREAD_CPUTIME_ID) - c0;
            usleep(200000);
        }
        smart_close(&h);
        printf("disk#%d %-8s resident: wall avg=%.2fms max=%.2fms cpu avg=%.3fms\n", i, loc, wall / n, wmax, cpu / n);
    }
}

static void cmd_pstate(int seconds, int interval) {
    CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("NVMe"), NULL, 0, 0, 0);
    CFMutableDictionaryRef sub = NULL;
    IOReportSubscriptionRef s = IOReportCreateSubscription(NULL, ch, &sub, 0, NULL);
    if (!s) { printf("subscription failed\n"); return; }
    io_object_t devs[32]; int count = collect(devs, 32);
    CFDictionaryRef a = IOReportCreateSamples(s, sub, NULL);
    double cpu = 0; int reads = 0;
    for (int t = 0; t < seconds; t++) {
        if (interval > 0 && t % interval == 0) {
            double c0 = now_ms(CLOCK_THREAD_CPUTIME_ID);
            for (int i = 0; i < count; i++) {
                smart_handle h; NVMeSMARTData d;
                if (smart_open(devs[i], &h)) { (*h.smart)->SMARTReadData(h.smart, &d); smart_close(&h); reads++; }
            }
            cpu += now_ms(CLOCK_THREAD_CPUTIME_ID) - c0;
        }
        sleep(1);
    }
    CFDictionaryRef b = IOReportCreateSamples(s, sub, NULL);
    CFDictionaryRef delta = IOReportCreateSamplesDelta(a, b, NULL);
    printf("window=%ds smart_interval=%ds reads=%d smart_cpu=%.2fms\n", seconds, interval, reads, cpu);
    IOReportIterate(delta, ^int(CFDictionaryRef c) {
        char name[128], drv[128];
        cfstr(IOReportChannelGetChannelName(c), name, sizeof name);
        if (strcmp(name, "NVMe Power States") != 0) return 0;
        cfstr(IOReportChannelGetDriverName(c), drv, sizeof drv);
        char *p = strstr(drv, " <"); if (p) *p = 0;  // 去掉 registry id
        printf("  %-26s", drv);
        int32_t n = IOReportStateGetCount(c); int64_t total = 0;
        for (int32_t i = 0; i < n; i++) total += IOReportStateGetResidency(c, i);
        for (int32_t i = 0; i < n; i++) {
            char st[64]; cfstr(IOReportStateGetNameForIndex(c, i), st, sizeof st);
            printf(" %s=%.1f%%", st, total ? 100.0 * IOReportStateGetResidency(c, i) / total : 0);
        }
        printf("\n");
        return 0;
    });
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "list")) cmd_list();
    else if (argc >= 3 && !strcmp(argv[1], "cost")) cmd_cost(atoi(argv[2]));
    else if (argc >= 4 && !strcmp(argv[1], "pstate")) cmd_pstate(atoi(argv[2]), atoi(argv[3]));
    else { fprintf(stderr, "usage: list | cost <n> | pstate <seconds> <interval>\n"); return 2; }
    return 0;
}
