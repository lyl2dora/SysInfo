// hidsensors.m - read-only probe of IOHIDEventSystemClient sensor services (private IOKit SPI)
// Build: xcrun clang -O2 -fobjc-arc -framework Foundation -framework IOKit hidsensors.m -o hidsensors
// Usage: ./hidsensors list            -> all services with PrimaryUsagePage/Usage/Product (vendor pages only)
//        ./hidsensors read N ms       -> temperature (ff00/5), current (ff08/2), voltage (ff08/3) N samples
#import <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
#define IOHIDEventFieldBase(type) (type << 16)
#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventTypePower 25

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
int64_t IOHIDEventGetType(IOHIDEventRef event);

static NSArray *services(IOHIDEventSystemClientRef sys, NSDictionary *match) {
    if (match) IOHIDEventSystemClientSetMatching(sys, (__bridge CFDictionaryRef)match);
    CFArrayRef s = IOHIDEventSystemClientCopyServices(sys);
    return s ? CFBridgingRelease(s) : @[];
}

static NSDictionary *readType(int page, int usage, int evType, int *nsvc, int *nnull) {
    IOHIDEventSystemClientRef sys = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    NSArray *svcs = services(sys, @{@"PrimaryUsagePage": @(page), @"PrimaryUsage": @(usage)});
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    *nsvc = (int)svcs.count; *nnull = 0;
    for (id o in svcs) {
        IOHIDServiceClientRef svc = (__bridge IOHIDServiceClientRef)o;
        NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(svc, CFSTR("Product")));
        NSNumber *loc = CFBridgingRelease(IOHIDServiceClientCopyProperty(svc, CFSTR("LocationID")));
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, evType, 0, 0);
        if (!ev) { (*nnull)++; continue; }
        double v = IOHIDEventGetFloatValue(ev, IOHIDEventFieldBase(evType));
        CFRelease(ev);
        NSString *k = name ?: [NSString stringWithFormat:@"<noname loc=%@>", loc];
        if (out[k]) k = [NSString stringWithFormat:@"%@ #dup%lu", k, (unsigned long)out.count];
        out[k] = @(v);
    }
    CFRelease(sys);
    return out;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc >= 2 && !strcmp(argv[1], "list")) {
            IOHIDEventSystemClientRef sys = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
            NSArray *all = services(sys, nil);
            printf("total HID services (no matching): %lu\n", (unsigned long)all.count);
            NSMutableDictionary<NSString *, NSMutableArray *> *byUsage = [NSMutableDictionary dictionary];
            for (id o in all) {
                IOHIDServiceClientRef svc = (__bridge IOHIDServiceClientRef)o;
                NSNumber *pg = CFBridgingRelease(IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsagePage")));
                NSNumber *us = CFBridgingRelease(IOHIDServiceClientCopyProperty(svc, CFSTR("PrimaryUsage")));
                NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(svc, CFSTR("Product")));
                NSString *k = [NSString stringWithFormat:@"page=0x%04lx usage=0x%04lx", pg.unsignedLongValue, us.unsignedLongValue];
                if (!byUsage[k]) byUsage[k] = [NSMutableArray array];
                [byUsage[k] addObject:name ?: @"(nil)"];
            }
            for (NSString *k in [byUsage.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                NSArray *names = byUsage[k];
                printf("%s  count=%lu  e.g. %s\n", k.UTF8String, (unsigned long)names.count,
                       [[names subarrayWithRange:NSMakeRange(0, MIN(6, names.count))] componentsJoinedByString:@" | "].UTF8String);
            }
            CFRelease(sys);
            return 0;
        }
        int N = argc >= 3 ? atoi(argv[2]) : 1, ms = argc >= 4 ? atoi(argv[3]) : 1000;
        struct { const char *label; int page, usage, ev; } kinds[] = {
            {"temperature ff00/0005 ev15", 0xff00, 0x0005, kIOHIDEventTypeTemperature},
            {"current     ff08/0002 ev25", 0xff08, 0x0002, kIOHIDEventTypePower},
            {"voltage     ff08/0003 ev25", 0xff08, 0x0003, kIOHIDEventTypePower},
            {"power?      ff08/0001 ev25", 0xff08, 0x0001, kIOHIDEventTypePower},
            {"temp page   ff05/0001 ev15", 0xff05, 0x0001, kIOHIDEventTypeTemperature},
        };
        for (int s = 0; s < N; s++) {
            printf("=== sample %d\n", s);
            for (size_t k = 0; k < sizeof kinds / sizeof kinds[0]; k++) {
                int nsvc, nnull;
                NSDictionary *d = readType(kinds[k].page, kinds[k].usage, kinds[k].ev, &nsvc, &nnull);
                printf("--- %s: services=%d nullEvents=%d values=%lu\n", kinds[k].label, nsvc, nnull, (unsigned long)d.count);
                for (NSString *name in [d.allKeys sortedArrayUsingSelector:@selector(compare:)])
                    printf("  %-40s %10.4f\n", name.UTF8String, [d[name] doubleValue]);
            }
            fflush(stdout);
            if (s < N - 1) usleep(ms * 1000);
        }
    }
    return 0;
}
