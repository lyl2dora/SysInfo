// IOReport "NVMe" group: power-state residency + BW-limit/throttle channels on the ANS controller (private libIOReport)
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int (^ioreportiterateblock)(CFDictionaryRef);
extern void IOReportIterate(CFDictionaryRef, ioreportiterateblock);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef), IOReportChannelGetSubGroup(CFDictionaryRef), IOReportChannelGetChannelName(CFDictionaryRef), IOReportChannelGetDriverName(CFDictionaryRef);
extern int IOReportChannelGetFormat(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int);
static void s(CFStringRef r, char *b, int n) { b[0] = 0; if (r) CFStringGetCString(r, b, n, kCFStringEncodingUTF8); }
int main(void) {
    CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("NVMe"), NULL, 0, 0, 0);
    if (!ch) { printf("no NVMe channels\n"); return 1; }
    CFArrayRef arr = CFDictionaryGetValue(ch, CFSTR("IOReportChannels"));
    printf("NVMe group channels: %ld\n", arr ? CFArrayGetCount(arr) : 0L);
    CFMutableDictionaryRef sub_ch = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, ch, &sub_ch, 0, NULL);
    if (!sub) { printf("subscription failed\n"); return 1; }
    CFDictionaryRef a = IOReportCreateSamples(sub, sub_ch, NULL);
    // generate a little I/O so power states move
    char path[1024]; snprintf(path, sizeof path, "%s/sysinfo-probe-ior.bin", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");  // 当前用户的临时目录
    FILE *f = fopen(path, "w");
    static char buf[1 << 20]; for (int i = 0; i < 64; i++) fwrite(buf, 1, sizeof buf, f); fflush(f); fsync(fileno(f)); fclose(f);
    unlink(path);
    sleep(2);
    CFDictionaryRef b = IOReportCreateSamples(sub, sub_ch, NULL);
    CFDictionaryRef d = IOReportCreateSamplesDelta(a, b, NULL);
    IOReportIterate(d, ^int(CFDictionaryRef c) {
        char g[64], sg[96], n[96], drv[128]; s(IOReportChannelGetGroup(c), g, 64); s(IOReportChannelGetSubGroup(c), sg, 96); s(IOReportChannelGetChannelName(c), n, 96); s(IOReportChannelGetDriverName(c), drv, 128);
        int fmt = IOReportChannelGetFormat(c);
        printf("  [%s/%s] '%s' drv=%s fmt=%d", g, sg, n, drv, fmt);
        if (fmt == 1) printf(" delta=%lld", IOReportSimpleGetIntegerValue(c, 0));
        else if (fmt == 2) { int k = IOReportStateGetCount(c); for (int i = 0; i < k; i++) { char sn[64]; s(IOReportStateGetNameForIndex(c, i), sn, 64); printf(" %s=%lld", sn, IOReportStateGetResidency(c, i)); } }
        printf("\n");
        return 0;
    });
    return 0;
}
