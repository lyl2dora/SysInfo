// hid_dedupe.m - how to tell apart the 3 same-named PMU temperature services (3 PMUs on M5 Pro): registry parent chain
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
int main(void) { @autoreleasepool {
    IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientSetMatching(c, (__bridge CFDictionaryRef)@{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5});
    NSArray *svcs = CFBridgingRelease(IOHIDEventSystemClientCopyServices(c));
    NSMutableArray *rows = [NSMutableArray array];
    for (id o in svcs) {
        IOHIDServiceClientRef s = (__bridge IOHIDServiceClientRef)o;
        NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(s, CFSTR("Product")));
        NSNumber *rid = (__bridge NSNumber *)IOHIDServiceClientGetRegistryID(s);
        NSNumber *loc = CFBridgingRelease(IOHIDServiceClientCopyProperty(s, CFSTR("LocationID")));
        io_registry_entry_t e = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(rid.unsignedLongLongValue));
        NSMutableArray *chain = [NSMutableArray array];
        io_registry_entry_t cur = e; IOObjectRetain(cur);
        for (int i = 0; i < 4 && cur; i++) {
            io_name_t n; IORegistryEntryGetName(cur, n); [chain addObject:@(n)];
            io_registry_entry_t p = 0; if (IORegistryEntryGetParentEntry(cur, kIOServicePlane, &p) != KERN_SUCCESS) p = 0;
            IOObjectRelease(cur); cur = p;
        }
        if (cur) IOObjectRelease(cur);
        io_name_t cls = ""; if (e) IOObjectGetClass(e, cls);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(s, 15, 0, 0);
        double v = ev ? IOHIDEventGetFloatValue(ev, 15 << 16) : NAN; if (ev) CFRelease(ev);
        [rows addObject:[NSString stringWithFormat:@"%-14s %8.2f  class=%s loc=%@ chain=%@", name.UTF8String, v, cls, loc, [chain componentsJoinedByString:@" < "]]];
        if (e) IOObjectRelease(e);
    }
    for (NSString *r in [rows sortedArrayUsingSelector:@selector(compare:)]) printf("%s\n", r.UTF8String);
    CFRelease(c);
} return 0; }
