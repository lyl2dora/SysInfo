// ioreport_sub.m - generic IOReport group/subgroup delta sampler (read-only). Usage: ./ioreport_sub "<group>" "<subgroup or ->" N ms
#import <Foundation/Foundation.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 3) { printf("usage\n"); return 2; }
    CFStringRef g = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFStringRef sg = strcmp(argv[2], "-") ? CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8) : NULL;
    int N = argc > 3 ? atoi(argv[3]) : 2, ms = argc > 4 ? atoi(argv[4]) : 1000;
    CFDictionaryRef chan = IOReportCopyChannelsInGroup(g, sg, 0, 0, 0);
    if (!chan) { printf("no channels\n"); return 1; }
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, chan);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, m, &subbed, 0, NULL);
    CFDictionaryRef prev = IOReportCreateSamples(sub, m, NULL);
    NSDate *tp = [NSDate date];
    for (int s = 0; s < N; s++) {
        usleep(ms * 1000);
        CFDictionaryRef cur = IOReportCreateSamples(sub, m, NULL);
        double dt = -[tp timeIntervalSinceNow]; tp = [NSDate date];
        NSDictionary *d = CFBridgingRelease(IOReportCreateSamplesDelta(prev, cur, NULL));
        CFRelease(prev); prev = cur;
        printf("=== %s / %s sample %d dt=%.3f\n", argv[1], argv[2], s, dt);
        for (NSDictionary *ch in d[@"IOReportChannels"]) {
            CFDictionaryRef c = (__bridge CFDictionaryRef)ch;
            int fmt = IOReportChannelGetFormat(c);
            NSString *n = (__bridge NSString *)IOReportChannelGetChannelName(c), *u = (__bridge NSString *)IOReportChannelGetUnitLabel(c);
            NSString *sgn = (__bridge NSString *)IOReportChannelGetSubGroup(c);
            if (fmt == 1) printf("  [%s] %-30s %14lld %s\n", sgn.UTF8String, n.UTF8String, IOReportSimpleGetIntegerValue(c, 0), u.UTF8String);
            else if (fmt == 2) {
                int32_t k = IOReportStateGetCount(c);
                printf("  [%s] %-30s state x%d:", sgn.UTF8String, n.UTF8String, k);
                for (int i = 0; i < k && i < 24; i++) { int64_t r = IOReportStateGetResidency(c, i); if (r) printf(" %s=%lld", [(__bridge NSString *)IOReportStateGetNameForIndex(c, i) UTF8String], r); }
                printf("\n");
            } else printf("  [%s] %-30s fmt=%d unit=%s\n", sgn.UTF8String, n.UTF8String, fmt, u.UTF8String);
        }
        fflush(stdout);
    }
} return 0; }
