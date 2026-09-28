// ioreport_abs.m - print ABSOLUTE (non-delta) Energy Model counters twice, 1 s apart, to see whether they are cumulative & advancing.
// Build: xcrun clang -O2 -fobjc-arc -framework Foundation -framework IOKit -lIOReport ioreport_abs.m -o ioreport_abs
#import <Foundation/Foundation.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
int main(int argc, const char **argv) { @autoreleasepool {
    NSString *group = argc > 1 ? @(argv[1]) : @"Energy Model";
    CFDictionaryRef chan = IOReportCopyChannelsInGroup((__bridge CFStringRef)group, NULL, 0, 0, 0);
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, chan);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, m, &subbed, 0, NULL);
    printf("subscription=%p subbedChannels=%ld\n", sub, subbed ? (long)[((__bridge NSDictionary *)subbed)[@"IOReportChannels"] count] : -1L);
    for (int s = 0; s < 2; s++) {
        NSDictionary *d = CFBridgingRelease(IOReportCreateSamples(sub, m, NULL));
        printf("=== absolute sample %d (%lu channels)\n", s, (unsigned long)[d[@"IOReportChannels"] count]);
        for (NSDictionary *ch in d[@"IOReportChannels"]) {
            NSString *n = (__bridge NSString *)IOReportChannelGetChannelName((__bridge CFDictionaryRef)ch);
            if ([n containsString:@"DTL"] || [n containsString:@"SRAM"]) continue;
            printf("  %-22s %16lld %s\n", n.UTF8String, IOReportSimpleGetIntegerValue((__bridge CFDictionaryRef)ch, 0),
                   [(__bridge NSString *)IOReportChannelGetUnitLabel((__bridge CFDictionaryRef)ch) UTF8String]);
        }
        if (s == 0) sleep(1);
    }
} return 0; }
