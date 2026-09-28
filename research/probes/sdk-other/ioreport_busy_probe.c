// Verify IOReport can be linked via the SDK stub ($SDKROOT/usr/lib/libIOReport.tbd,
// i.e. plain -lIOReport) with no headers (declared manually), and that it returns
// plausible data unprivileged. Also checks the 27-only export IOReportCreateSnapshotDeltas
// via dlsym and libSMC.dylib loadability. Read-only.
#include <stdio.h>
#include <dlfcn.h>
#include <unistd.h>
#include <time.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
extern CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
extern int IOReportGetChannelCount(CFDictionaryRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desired, CFMutableDictionaryRef *subbed, uint64_t channel_id, CFTypeRef b);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t *);

static void pr(CFStringRef s) { char b[256] = "?"; if (s) CFStringGetCString(s, b, sizeof b, kCFStringEncodingUTF8); printf("%s", b); }

int main(void) {
    CFMutableDictionaryRef all = IOReportCopyAllChannels(0, 0);
    printf("IOReportCopyAllChannels: %d channels\n", all ? IOReportGetChannelCount(all) : -1);
    if (all) CFRelease(all);

    CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    printf("Energy Model channels: %d\n", ch ? IOReportGetChannelCount(ch) : -1);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, ch, &subbed, 0, NULL);
    printf("subscription=%p\n", (void *)sub);
    if (sub) {
        CFDictionaryRef s1 = IOReportCreateSamples(sub, subbed, NULL);
        { volatile double x=0; time_t t0=time(NULL); while (time(NULL)-t0 < 2) x+=1; }
        CFDictionaryRef s2 = IOReportCreateSamples(sub, subbed, NULL);
        CFDictionaryRef d = IOReportCreateSamplesDelta(s1, s2, NULL);
        CFArrayRef arr = d ? CFDictionaryGetValue(d, CFSTR("IOReportChannels")) : NULL;
        CFIndex n = arr ? CFArrayGetCount(arr) : 0;
        int shown = 0;
        for (CFIndex i = 0; i < n && shown < 400; i++) {
            CFDictionaryRef item = CFArrayGetValueAtIndex(arr, i);
            CFStringRef name = IOReportChannelGetChannelName(item);
            char b[128] = ""; if (name) CFStringGetCString(name, b, sizeof b, kCFStringEncodingUTF8);
            long long v = IOReportSimpleGetIntegerValue(item, NULL); if (v != 0) {
                printf("  %-20s delta=%lld ", b, (long long)IOReportSimpleGetIntegerValue(item, NULL));
                pr(IOReportChannelGetUnitLabel(item)); printf("\n"); shown++;
            }
        }
        printf("delta channels=%ld\n", (long)n);
    }

    void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    printf("dlopen libIOReport=%p IOReportCreateSnapshotDeltas=%p\n", h, h ? dlsym(h, "IOReportCreateSnapshotDeltas") : NULL);
    void *s = dlopen("/usr/lib/libSMC.dylib", RTLD_NOW);
    printf("dlopen libSMC=%p SMCOpenConnection=%p\n", s, s ? dlsym(s, "SMCOpenConnection") : NULL);
    return 0;
}
