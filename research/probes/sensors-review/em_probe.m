// em_probe.m - independent check of IOReport "Energy Model": driver/channel IDs, duplicates,
// and delta sampling via IOReportCreateSamplesDelta + IOReportIterate (different path than the original probe).
// Usage: ./em_probe info            -> list channels with driver name/id, channel id, unit, format
//        ./em_probe delta N ms      -> N deltas, prints W for CPU Energy / GPU Energy / PCPU / MCPU0 / MCPU1 / DRAM0 / GPU0 / ANE0
//        ./em_probe fresh N ms      -> NEW subscription for every sample (tests whether a fresh subscription refreshes values)
#import <Foundation/Foundation.h>
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
uint64_t IOReportChannelGetDriverID(CFDictionaryRef);
uint64_t IOReportChannelGetChannelID(CFDictionaryRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
typedef int (^ioreportiterateblock)(CFDictionaryRef ch);
void IOReportIterate(CFDictionaryRef samples, ioreportiterateblock);

static double scale(NSString *u) { if ([u isEqual:@"mJ"]) return 1e-3; if ([u isEqual:@"uJ"]) return 1e-6; if ([u isEqual:@"nJ"]) return 1e-9; return NAN; }
static NSArray *want(void) { return @[@"CPU Energy", @"PCPU", @"MCPU0", @"MCPU1", @"GPU0", @"GPU Energy", @"DRAM0", @"ANE0", @"AMCC0", @"FAB0"]; }

int main(int argc, const char **argv) { @autoreleasepool {
    const char *mode = argc > 1 ? argv[1] : "info";
    CFDictionaryRef chan = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!strcmp(mode, "info")) {
        NSMutableDictionary *cnt = [NSMutableDictionary dictionary];
        NSMutableDictionary *drv = [NSMutableDictionary dictionary];
        for (NSDictionary *ch in ((__bridge NSDictionary *)chan)[@"IOReportChannels"]) {
            CFDictionaryRef c = (__bridge CFDictionaryRef)ch;
            NSString *n = (__bridge NSString *)IOReportChannelGetChannelName(c);
            NSString *d = (__bridge NSString *)IOReportChannelGetDriverName(c);
            NSString *dk = [NSString stringWithFormat:@"%@ id=0x%llx", d, IOReportChannelGetDriverID(c)];
            drv[dk] = @([drv[dk] intValue] + 1);
            cnt[n] = @([cnt[n] intValue] + 1);
            if ([want() containsObject:n])
                printf("%-12s driver=%s chanID=0x%llx unit=%s fmt=%d\n", n.UTF8String, dk.UTF8String, IOReportChannelGetChannelID(c),
                       [(__bridge NSString *)IOReportChannelGetUnitLabel(c) UTF8String], IOReportChannelGetFormat(c));
        }
        printf("drivers providing Energy Model channels:\n"); for (NSString *k in drv) printf("  %s : %d channels\n", k.UTF8String, [drv[k] intValue]);
        int dups = 0; for (NSString *k in cnt) if ([cnt[k] intValue] > 1) { dups++; printf("  DUP name %s x%d\n", k.UTF8String, [cnt[k] intValue]); }
        printf("unique names=%lu dups=%d total=%lu\n", (unsigned long)cnt.count, dups, (unsigned long)[((__bridge NSDictionary *)chan)[@"IOReportChannels"] count]);
        return 0;
    }
    int N = argc > 2 ? atoi(argv[2]) : 5, ms = argc > 3 ? atoi(argv[3]) : 1000;
    BOOL fresh = !strcmp(mode, "fresh");
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, chan);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, m, &subbed, 0, NULL);
    CFDictionaryRef prev = IOReportCreateSamples(sub, subbed, NULL);
    NSDate *tp = [NSDate date];
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss";
    printf("%-8s %6s", "time", "dt"); for (NSString *w in want()) printf(" %10s", w.UTF8String); printf("   (W)\n");
    for (int i = 0; i < N; i++) {
        usleep(ms * 1000);
        if (fresh) { // brand-new subscription, take two samples 100 ms apart? no: compare against prev from old sub (values are absolute)
            CFMutableDictionaryRef m2 = CFDictionaryCreateMutableCopy(NULL, 0, IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0));
            CFMutableDictionaryRef s2 = NULL; sub = IOReportCreateSubscription(NULL, m2, &s2, 0, NULL); subbed = s2;
        }
        CFDictionaryRef cur = IOReportCreateSamples(sub, subbed, NULL);
        NSDate *tc = [NSDate date]; double dt = [tc timeIntervalSinceDate:tp];
        CFDictionaryRef delta = IOReportCreateSamplesDelta(prev, cur, NULL);
        double wbuf[16]; double *w = wbuf; for (int k = 0; k < 16; k++) w[k] = NAN;
        NSArray *wl = want();
        IOReportIterate(delta, ^int(CFDictionaryRef c) {
            NSString *n = (__bridge NSString *)IOReportChannelGetChannelName(c);
            NSUInteger ix = [wl indexOfObject:n];
            if (ix != NSNotFound) w[ix] = IOReportSimpleGetIntegerValue(c, 0) * scale((__bridge NSString *)IOReportChannelGetUnitLabel(c)) / dt;
            return 0;
        });
        printf("%-8s %6.3f", [f stringFromDate:tc].UTF8String, dt); for (NSUInteger k = 0; k < wl.count; k++) printf(" %10.3f", w[k]); printf("\n");
        fflush(stdout);
        CFRelease(delta); CFRelease(prev); prev = cur; tp = tc;
    }
} return 0; }
