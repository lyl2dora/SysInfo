// hid_all.m — 不带匹配条件列出全部 HID 事件服务，按 (PrimaryUsagePage, PrimaryUsage) 分组计数并列出名称样例；
// 另外搜索名称里含 ACC / MTR / SOC / GPU / CPU 的服务（M1/M2 旧系统上的 pACC/eACC MTR 温度传感器）。只读。
#import <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int main(void){ @autoreleasepool {
  IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  NSArray *svcs = CFBridgingRelease(IOHIDEventSystemClientCopyServices(c));
  NSMutableDictionary *g=[NSMutableDictionary dictionary]; NSMutableArray *hits=[NSMutableArray array];
  for(id o in svcs){ IOHIDServiceClientRef s=(__bridge IOHIDServiceClientRef)o;
    NSNumber *pg=CFBridgingRelease(IOHIDServiceClientCopyProperty(s,CFSTR("PrimaryUsagePage"))); NSNumber *us=CFBridgingRelease(IOHIDServiceClientCopyProperty(s,CFSTR("PrimaryUsage")));
    NSString *nm=CFBridgingRelease(IOHIDServiceClientCopyProperty(s,CFSTR("Product"))) ?: @"(nil)";
    NSString *k=[NSString stringWithFormat:@"page=0x%04lx usage=0x%04lx",pg.longValue,us.longValue]; if(!g[k]) g[k]=[NSMutableSet set]; [g[k] addObject:nm];
    NSString *u=nm.uppercaseString; if([u containsString:@"ACC"]||[u containsString:@"MTR"]||[u containsString:@"SOC"]||[u containsString:@"GPU"]||[u containsString:@"CPU"]) [hits addObject:[NSString stringWithFormat:@"%@ (%@)",nm,k]]; }
  printf("total services=%lu\n",(unsigned long)svcs.count);
  for(NSString*k in [g.allKeys sortedArrayUsingSelector:@selector(compare:)]){ NSArray*a=[[g[k] allObjects] sortedArrayUsingSelector:@selector(compare:)]; printf("%s distinct=%lu e.g. %s\n",k.UTF8String,(unsigned long)a.count,[[[a subarrayWithRange:NSMakeRange(0,MIN(8,a.count))] componentsJoinedByString:@" | "] UTF8String]); }
  printf("ACC/MTR/SOC/GPU/CPU name hits: %lu\n",(unsigned long)hits.count); for(NSString*h in hits) printf("  %s\n",h.UTF8String);
  CFRelease(c); } return 0; }
