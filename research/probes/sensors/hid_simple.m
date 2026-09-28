// hid_simple.m - does the PUBLIC IOHIDEventSystemClientCreateSimpleClient() see the PMU temperature services? (event read still needs private IOHIDServiceClientCopyEvent)
#import <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
int main(void) { @autoreleasepool {
    IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    NSArray *svcs = CFBridgingRelease(IOHIDEventSystemClientCopyServices(c));
    int temp = 0, ok = 0; double sample = NAN; NSString *sname = nil;
    for (id o in svcs) {
        IOHIDServiceClientRef s = (__bridge IOHIDServiceClientRef)o;
        if (IOHIDServiceClientConformsTo(s, 0xff00, 0x0005)) {
            temp++;
            IOHIDEventRef e = IOHIDServiceClientCopyEvent(s, 15, 0, 0);
            if (e) { ok++; if (!sname) { sample = IOHIDEventGetFloatValue(e, 15 << 16); sname = CFBridgingRelease(IOHIDServiceClientCopyProperty(s, CFSTR("Product"))); } CFRelease(e); }
        }
    }
    printf("simple client: services=%lu conformTo(ff00,5)=%d events ok=%d e.g. %s=%.2f\n", (unsigned long)svcs.count, temp, ok, sname.UTF8String, sample);
    CFRelease(c);
} return 0; }
