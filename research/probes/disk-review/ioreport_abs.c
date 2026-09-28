// Review probe: IOReport NVMe group ABSOLUTE values (not deltas) + delta, to check BW Scale Factor semantics
// and power-state residency since driver start (for the power-on-hours question).
#include <stdio.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int (^ioreportiterateblock)(CFDictionaryRef);
extern void IOReportIterate(CFDictionaryRef, ioreportiterateblock);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef), IOReportChannelGetChannelName(CFDictionaryRef), IOReportChannelGetDriverName(CFDictionaryRef), IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int IOReportChannelGetFormat(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int);
static void s(CFStringRef r, char *b, int n) { b[0] = 0; if (r) CFStringGetCString(r, b, n, kCFStringEncodingUTF8); }
static void dump(CFDictionaryRef d, const char *tag) {
    IOReportIterate(d, ^int(CFDictionaryRef c) {
        char sg[96], n[96], drv[128], u[32]; s(IOReportChannelGetSubGroup(c), sg, 96); s(IOReportChannelGetChannelName(c), n, 96); s(IOReportChannelGetDriverName(c), drv, 128); s(IOReportChannelGetUnitLabel(c), u, 32);
        int fmt = IOReportChannelGetFormat(c);
        printf("%s [%s] '%s' drv=%.40s unit='%s' fmt=%d", tag, sg, n, drv, u, fmt);
        if (fmt == 1) printf(" value=%lld", IOReportSimpleGetIntegerValue(c, 0));
        else if (fmt == 2) { int k = IOReportStateGetCount(c); for (int i = 0; i < k; i++) { char sn[64]; s(IOReportStateGetNameForIndex(c, i), sn, 64); printf(" %s=%lld", sn, IOReportStateGetResidency(c, i)); } }
        printf("\n");
        return 0;
    });
}
int main(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    printf("mach_absolute_time=%llu (awake s=%.0f) mach_continuous_time=%llu (s=%.0f) timebase %u/%u\n",
      mach_absolute_time(), (double)mach_absolute_time()*tb.numer/tb.denom/1e9, mach_continuous_time(), (double)mach_continuous_time()*tb.numer/tb.denom/1e9, tb.numer, tb.denom);
    CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("NVMe"), NULL, 0, 0, 0);
    CFMutableDictionaryRef sub_ch = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, ch, &sub_ch, 0, NULL);
    CFDictionaryRef a = IOReportCreateSamples(sub, sub_ch, NULL);
    dump(a, "ABS");
    sleep(5);
    CFDictionaryRef b = IOReportCreateSamples(sub, sub_ch, NULL);
    CFDictionaryRef d = IOReportCreateSamplesDelta(a, b, NULL);
    dump(d, "DELTA5s");
    return 0;
}
