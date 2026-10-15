// sk_hid.c — 独立复核 HID 温度服务（私有 IOHIDEventSystemClient；usage page 0xff00 / usage 5）：服务数、不同名字数、是否有 ACC/MTR/SOC/CPU/GPU 名字、一次全读的线程 CPU 开销。只读。
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
static double tcpu(void){ struct timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t); return t.tv_sec*1e3+t.tv_nsec/1e6; }
int main(void){
  double c0=tcpu(); IOHIDEventSystemClientRef cl=IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  int page=0xff00, usage=5; CFNumberRef p=CFNumberCreate(NULL,kCFNumberIntType,&page), u=CFNumberCreate(NULL,kCFNumberIntType,&usage);
  const void*k[]={CFSTR("PrimaryUsagePage"),CFSTR("PrimaryUsage")}; const void*v[]={p,u};
  CFDictionaryRef m=CFDictionaryCreate(NULL,k,v,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks); IOHIDEventSystemClientSetMatching(cl,m);
  CFArrayRef sv=IOHIDEventSystemClientCopyServices(cl); double c1=tcpu(); long n=sv?CFArrayGetCount(sv):0;
  char names[256][64]; int nn=0, hits=0;
  for(long i=0;i<n;i++){ IOHIDServiceClientRef s=(IOHIDServiceClientRef)CFArrayGetValueAtIndex(sv,i); CFStringRef pr=IOHIDServiceClientCopyProperty(s,CFSTR("Product")); char b[64]="(nil)"; if(pr){ CFStringGetCString(pr,b,64,kCFStringEncodingUTF8); CFRelease(pr);} 
    int f=0; for(int j=0;j<nn;j++) if(!strcmp(names[j],b)) f=1; if(!f&&nn<256) strcpy(names[nn++],b);
    if(strstr(b,"ACC")||strstr(b,"MTR")||strstr(b,"SOC")||strstr(b,"CPU")||strstr(b,"GPU")) hits++; }
  double best=1e9; for(int r=0;r<5;r++){ double a=tcpu(); for(long i=0;i<n;i++){ IOHIDEventRef e=IOHIDServiceClientCopyEvent((IOHIDServiceClientRef)CFArrayGetValueAtIndex(sv,i),15,0,0); if(e){ (void)IOHIDEventGetFloatValue(e,15<<16); CFRelease(e);} } double d=tcpu()-a; if(r>0&&d<best) best=d; }
  printf("服务=%ld 不同名字=%d 名字含 ACC/MTR/SOC/CPU/GPU 的服务=%d；建客户端+枚举 %.2f ms CPU；全读（热态最小值）%.2f ms CPU\n名字：",n,nn,hits,c1-c0,best);
  for(int j=0;j<nn;j++) printf("%s | ",names[j]); printf("\n"); return 0; }
