// ioreport_power.m - read-only IOReport probe (private libIOReport) for energy/power channels.
// Build: xcrun clang -O2 -fobjc-arc -framework Foundation -framework IOKit -lIOReport ioreport_power.m -o ioreport_power
// Usage: ./ioreport_power groups              -> group/subgroup channel counts; channels of power-ish groups with units
//        ./ioreport_power energy N ms [group] -> delta sampling of a group (default "Energy Model"), watts per channel
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
typedef CFDictionaryRef IOReportSampleRef;
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
int32_t IOReportStateGetCount(CFDictionaryRef);

static NSString *S(CFStringRef s) { return s ? (__bridge NSString *)s : @"(nil)"; }

static double toJoules(double v, NSString *unit) {
    if ([unit isEqualToString:@"mJ"]) return v / 1e3;
    if ([unit isEqualToString:@"uJ"]) return v / 1e6;
    if ([unit isEqualToString:@"nJ"]) return v / 1e9;
    return NAN;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc >= 2 && !strcmp(argv[1], "groups")) {
            NSDictionary *all = CFBridgingRelease(IOReportCopyAllChannels(0, 0));
            NSArray *chs = all[@"IOReportChannels"];
            printf("IOReportCopyAllChannels: %lu channels\n", (unsigned long)chs.count);
            NSMutableDictionary<NSString *, NSNumber *> *cnt = [NSMutableDictionary dictionary];
            NSMutableArray *interesting = [NSMutableArray array];
            for (NSDictionary *ch in chs) {
                CFDictionaryRef c = (__bridge CFDictionaryRef)ch;
                NSString *g = S(IOReportChannelGetGroup(c)), *sg = S(IOReportChannelGetSubGroup(c));
                NSString *k = [NSString stringWithFormat:@"%@ / %@", g, sg];
                cnt[k] = @(cnt[k].intValue + 1);
                NSString *unit = S(IOReportChannelGetUnitLabel(c));
                NSString *name = S(IOReportChannelGetChannelName(c));
                BOOL pw = [g rangeOfString:@"Energy"].location != NSNotFound || [g rangeOfString:@"Power"].location != NSNotFound ||
                          [g isEqualToString:@"PMP"] || [unit hasSuffix:@"J"] || [unit hasSuffix:@"W"] || [unit isEqualToString:@"mV"] || [unit isEqualToString:@"mA"];
                if (pw) [interesting addObject:[NSString stringWithFormat:@"  [%@ / %@] %@  unit=%@ fmt=%d", g, sg, name, unit, IOReportChannelGetFormat(c)]];
            }
            printf("\n== group / subgroup : channel count\n");
            for (NSString *k in [cnt.allKeys sortedArrayUsingSelector:@selector(compare:)]) printf("  %-60s %d\n", k.UTF8String, cnt[k].intValue);
            printf("\n== power/energy-ish channels (%lu)\n", (unsigned long)interesting.count);
            for (NSString *s in interesting) printf("%s\n", s.UTF8String);
            return 0;
        }
        if (argc >= 2 && !strcmp(argv[1], "energy")) {
            int N = argc >= 3 ? atoi(argv[2]) : 3, ms = argc >= 4 ? atoi(argv[3]) : 1000;
            NSString *group = argc >= 5 ? @(argv[4]) : @"Energy Model";
            CFDictionaryRef chan = IOReportCopyChannelsInGroup((__bridge CFStringRef)group, NULL, 0, 0, 0);
            if (!chan) { printf("no channels in group %s\n", group.UTF8String); return 1; }
            CFMutableDictionaryRef mchan = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(chan), chan);
            CFRelease(chan);
            CFMutableDictionaryRef subbed = NULL;
            IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, mchan, &subbed, 0, NULL);
            if (!sub) { printf("IOReportCreateSubscription failed\n"); return 1; }
            CFDictionaryRef prev = IOReportCreateSamples(sub, mchan, NULL);
            NSDate *tprev = [NSDate date];
            for (int s = 0; s < N; s++) {
                usleep(ms * 1000);
                CFDictionaryRef cur = IOReportCreateSamples(sub, mchan, NULL);
                NSDate *tcur = [NSDate date];
                double dt = [tcur timeIntervalSinceDate:tprev];
                NSDictionary *delta = CFBridgingRelease(IOReportCreateSamplesDelta(prev, cur, NULL));
                CFRelease(prev); prev = cur; tprev = tcur;
                printf("=== sample %d dt=%.3fs group=%s\n", s, dt, group.UTF8String);
                double sumAll = 0, statsCPU = 0, statsGPU = 0, statsANE = 0, statsRAM = 0, statsPCI = 0;
                double sumCPUsuffix = 0; int nCPUsuffix = 0;
                for (NSDictionary *ch in delta[@"IOReportChannels"]) {
                    CFDictionaryRef c = (__bridge CFDictionaryRef)ch;
                    NSString *name = S(IOReportChannelGetChannelName(c)), *unit = S(IOReportChannelGetUnitLabel(c));
                    int fmt = IOReportChannelGetFormat(c);
                    if (fmt != 1) { printf("  %-28s fmt=%d (non-simple) unit=%s\n", name.UTF8String, fmt, unit.UTF8String); continue; }
                    int64_t v = IOReportSimpleGetIntegerValue(c, 0);
                    double j = toJoules((double)v, unit);
                    double w = isnan(j) ? NAN : j / dt;
                    printf("  %-28s %14lld %-3s  %8.3f W\n", name.UTF8String, v, unit.UTF8String, w);
                    if (!isnan(w)) sumAll += w;
                    // replicate Stats' matching (readers.swift:578-588): last match wins
                    if ([name hasSuffix:@"CPU Energy"]) { statsCPU = w; sumCPUsuffix += w; nCPUsuffix++; }
                    else if ([name hasSuffix:@"GPU Energy"]) statsGPU = w;
                    else if ([name hasPrefix:@"ANE"]) statsANE = w;
                    else if ([name hasPrefix:@"DRAM"]) statsRAM = w;
                    else if ([name hasPrefix:@"PCI"] && [name hasSuffix:@"Energy"]) statsPCI = w;
                }
                printf("  -> sum(all simple energy channels)=%.3f W | Stats-style CPU=%.3f (n matches=%d, sum=%.3f) GPU=%.3f ANE=%.3f DRAM=%.3f PCI=%.3f\n",
                       sumAll, statsCPU, nCPUsuffix, sumCPUsuffix, statsGPU, statsANE, statsRAM, statsPCI);
                fflush(stdout);
            }
            CFRelease(prev);
            return 0;
        }
        printf("usage: ioreport_power groups | energy N ms [group]\n");
    }
    return 0;
}
