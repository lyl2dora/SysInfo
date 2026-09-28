// variant: samples with the SUBSCRIBED channel dict (output of IOReportCreateSubscription), as macmon/socpowerbud do
// ioreport_cadence.m - how often do Energy Model counters advance? prints CPU Energy / GPU0 / DRAM0 / GPU Energy every 250 ms.
#import <Foundation/Foundation.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
int main(int argc, const char **argv) { @autoreleasepool {
    int N = argc > 1 ? atoi(argv[1]) : 60, ms = argc > 2 ? atoi(argv[2]) : 250;
    CFDictionaryRef chan = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, chan);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, m, &subbed, 0, NULL);
    NSArray *want = @[@"CPU Energy", @"PCPU", @"MCPU0", @"GPU0", @"DRAM0", @"ANE0", @"GPU Energy"];
    int64_t last[16] = {0}; double tlast = 0; NSDate *t0 = [NSDate date];
    printf("t(s)    "); for (NSString *w in want) printf("%16s", w.UTF8String); printf("\n");
    for (int s = 0; s < N; s++) {
        NSDictionary *d = CFBridgingRelease(IOReportCreateSamples(sub, subbed, NULL));
        double t = -[t0 timeIntervalSinceNow];
        int64_t v[16] = {0};
        for (NSDictionary *ch in d[@"IOReportChannels"]) {
            NSString *n = (__bridge NSString *)IOReportChannelGetChannelName((__bridge CFDictionaryRef)ch);
            NSUInteger i = [want indexOfObject:n];
            if (i != NSNotFound) v[i] = IOReportSimpleGetIntegerValue((__bridge CFDictionaryRef)ch, 0);
        }
        BOOL changed = NO; for (NSUInteger i = 0; i + 1 < want.count; i++) if (v[i] != last[i]) changed = YES;
        if (s == 0 || changed) {
            printf("%6.2f  ", t);
            for (NSUInteger i = 0; i < want.count; i++) printf("%16lld", s ? v[i] - last[i] : v[i]);
            printf("   %s dt_since_change=%.2f\n", s ? "(delta)" : "(abs)", t - tlast);
            tlast = t;
            memcpy(last, v, sizeof v);
        }
        fflush(stdout);
        usleep(ms * 1000);
    }
} return 0; }
