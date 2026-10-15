// hid_watch.m — 每秒（对齐整秒）记录全部 HID 温度服务（0xff00/5）读数到 CSV，列名 = Product#LocationID#序号（同名多次注册分别记录）。
// 用于与 tp_watch 的负载阶段按时间戳对齐，判断 HID 传感器随哪个簇变化。只读。用法：hid_watch out.csv 秒数
#import <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <time.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
static double wall(void){ struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }
int main(int argc, char **argv){ @autoreleasepool {
  if(argc<3){ fprintf(stderr,"usage: hid_watch out.csv secs\n"); return 2; }
  IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  IOHIDEventSystemClientSetMatching(c, (__bridge CFDictionaryRef)@{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5});
  NSArray *svcs = CFBridgingRelease(IOHIDEventSystemClientCopyServices(c));
  NSMutableArray *names=[NSMutableArray array]; NSMutableDictionary *seen=[NSMutableDictionary dictionary];
  for(id o in svcs){ IOHIDServiceClientRef s=(__bridge IOHIDServiceClientRef)o; NSString *n=CFBridgingRelease(IOHIDServiceClientCopyProperty(s,CFSTR("Product")))?:@"nil";
    NSNumber *loc=CFBridgingRelease(IOHIDServiceClientCopyProperty(s,CFSTR("LocationID"))); NSString *k=[NSString stringWithFormat:@"%@#%@",n,loc];
    int i=[seen[k] intValue]; seen[k]=@(i+1); [names addObject:[[NSString stringWithFormat:@"%@#%d",k,i] stringByReplacingOccurrencesOfString:@" " withString:@"_"]]; }
  FILE *fo=fopen(argv[1],"w"); fprintf(fo,"t"); for(NSString*n in names) fprintf(fo,",%s",n.UTF8String); fprintf(fo,"\n");
  int secs=atoi(argv[2]); double next=floor(wall())+1;
  for(int s=0;s<secs;s++){ double now=wall(); if(now<next) usleep((useconds_t)((next-now)*1e6)); next+=1; fprintf(fo,"%.3f",wall());
    for(id o in svcs){ IOHIDEventRef ev=IOHIDServiceClientCopyEvent((__bridge IOHIDServiceClientRef)o,15,0,0); double v=ev?IOHIDEventGetFloatValue(ev,15<<16):NAN; if(ev) CFRelease(ev); fprintf(fo,",%.3f",v); }
    fprintf(fo,"\n"); fflush(fo); }
  fclose(fo); CFRelease(c); } return 0; }
