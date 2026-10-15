// hid_temps.m — 列出私有 IOHIDEventSystemClient 下的温度传感器服务（usage page 0xff00 / usage 5），
// 打印 Product、LocationID、驱动类、注册次数与当前值，并测量「建客户端+枚举」与「每次读全部事件」的线程 CPU 开销。只读。
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <time.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
static double tcpu(void){ struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&ts); return ts.tv_sec*1e3+ts.tv_nsec/1e6; }
int main(void) { @autoreleasepool {
    double c0=tcpu();
    IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientSetMatching(c, (__bridge CFDictionaryRef)@{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5});
    NSArray *svcs = CFBridgingRelease(IOHIDEventSystemClientCopyServices(c));
    double c1=tcpu();
    NSMutableDictionary<NSString*, NSMutableArray*> *by = [NSMutableDictionary dictionary];
    for (id o in svcs) {
        IOHIDServiceClientRef s = (__bridge IOHIDServiceClientRef)o;
        NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(s, CFSTR("Product"))) ?: @"(nil)";
        NSNumber *loc = CFBridgingRelease(IOHIDServiceClientCopyProperty(s, CFSTR("LocationID")));
        NSNumber *rid = (__bridge NSNumber *)IOHIDServiceClientGetRegistryID(s);
        io_registry_entry_t e = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(rid.unsignedLongLongValue));
        io_name_t cls = "?"; if (e) { IOObjectGetClass(e, cls); IOObjectRelease(e); }
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(s, 15, 0, 0);
        double v = ev ? IOHIDEventGetFloatValue(ev, 15 << 16) : NAN; if (ev) CFRelease(ev);
        NSString *k = [NSString stringWithFormat:@"%@|%s", name, cls];
        if (!by[k]) by[k] = [NSMutableArray array];
        [by[k] addObject:[NSString stringWithFormat:@"%.2f@%@", v, loc]];
    }
    double c2=tcpu();
    printf("services=%lu distinct(name|class)=%lu  create+match+copyServices %.2f ms CPU; first read-all %.2f ms CPU\n", (unsigned long)svcs.count, (unsigned long)by.count, c1-c0, c2-c1);
    for (NSString *k in [by.allKeys sortedArrayUsingSelector:@selector(compare:)]) printf("  %-40s x%lu  %s\n", k.UTF8String, (unsigned long)by[k].count, [[by[k] componentsJoinedByString:@" "] UTF8String]);
    // 稳态开销：重复读全部服务 20 次（复用 services 数组，只 CopyEvent）
    double best[20];
    for (int r = 0; r < 20; r++) { double a=tcpu(); for (id o in svcs) { IOHIDEventRef ev = IOHIDServiceClientCopyEvent((__bridge IOHIDServiceClientRef)o, 15, 0, 0); if (ev) CFRelease(ev); } best[r]=tcpu()-a; usleep(100000); }
    double s=0; for(int r=0;r<20;r++) s+=best[r];
    // 中位数
    for(int i=0;i<20;i++) for(int j=i+1;j<20;j++) if(best[j]<best[i]){ double t=best[i]; best[i]=best[j]; best[j]=t; }
    printf("steady read-all (%lu services): mean %.3f ms, median %.3f ms CPU per pass\n", (unsigned long)svcs.count, s/20, (best[9]+best[10])/2);
    CFRelease(c);
} return 0; }
