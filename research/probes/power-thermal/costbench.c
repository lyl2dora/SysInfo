// costbench.c - 真实节奏（每 1 s 醒来一次）下的读取开销：
//   A) SMC 3 键（PDTR + 热点 + F0Ac）；B) SMC 15 键（面板功耗分解）；
//   C) 只订阅 Energy Model 里的 AGX「GPU Energy」一个通道；D) PowerTelemetryData。
// 只读：SMC 只用 selector 2 的 cmd 9/5。build: xcrun clang -O2 -framework IOKit -framework CoreFoundation -lIOReport costbench.c -o costbench
// usage: costbench <hotkey> <n_seconds>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t conn;
static uint32_t k4(const char *s){ return (uint32_t)s[0]<<24|(uint32_t)s[1]<<16|(uint32_t)s[2]<<8|(uint32_t)s[3]; }
static float rd(const char *k){ SMCParam in={0},out={0}; size_t sz=sizeof out; in.key=k4(k); in.keyInfo.dataSize=4; in.data8=5;
  if(IOConnectCallStructMethod(conn,2,&in,sizeof in,&out,&sz)||out.result) return -1; float f; memcpy(&f,out.bytes,4); return f; }
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
static double tc(void){ struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&ts); return ts.tv_sec*1e3+ts.tv_nsec/1e6; }
static int cmpd(const void*a,const void*b){ double x=*(double*)a,y=*(double*)b; return x<y?-1:x>y; }
int main(int argc,char**argv){
  const char *hot=argv[1]; int N=atoi(argv[2]);
  io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC")); IOServiceOpen(s,mach_task_self(),0,&conn);
  const char *k3[]={"PDTR",hot,"F0Ac"}; const char *k15[]={"PDTR","PZC0","PHPC","PZD1","RP00","RP01","RP02","RP04","RP05","RP06","PPSR",hot,"TCMb","F0Ac","F0Tg"};
  // AGX 单通道订阅
  CFMutableDictionaryRef all=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
  CFArrayRef arr=CFDictionaryGetValue(all,CFSTR("IOReportChannels")); CFMutableArrayRef one=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); if(CFEqual(IOReportChannelGetChannelName(c),CFSTR("GPU Energy"))) CFArrayAppendValue(one,c); }
  CFMutableDictionaryRef d=CFDictionaryCreateMutableCopy(NULL,0,all); CFDictionarySetValue(d,CFSTR("IOReportChannels"),one);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,d,&subbed,0,NULL);
  io_service_t bat=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSmartBattery"));
  double A[64],B[64],C[64],Dd[64]; volatile float sink=0;
  for(int n=0;n<N;n++){ sleep(1);
    double t0=tc(); for(int i=0;i<3;i++) sink+=rd(k3[i]); double t1=tc(); A[n]=t1-t0; sleep(1);
    t0=tc(); for(int i=0;i<15;i++) sink+=rd(k15[i]); t1=tc(); B[n]=t1-t0; sleep(1);
    t0=tc(); CFDictionaryRef smp=IOReportCreateSamples(sub,subbed,NULL); CFRelease(smp); t1=tc(); C[n]=t1-t0; sleep(1);
    t0=tc(); CFTypeRef p=IORegistryEntryCreateCFProperty(bat,CFSTR("PowerTelemetryData"),NULL,0); if(p) CFRelease(p); t1=tc(); Dd[n]=t1-t0; }
  qsort(A,N,8,cmpd); qsort(B,N,8,cmpd); qsort(C,N,8,cmpd); qsort(Dd,N,8,cmpd);
  printf("AGX 单通道订阅 %ld 个通道\n",(long)CFArrayGetCount(one));
  printf("真实节奏线程 CPU 中位数（ms）：SMC 3 键 %.3f · SMC 15 键 %.3f · AGX 单通道 %.3f · PowerTelemetryData %.3f\n",A[N/2],B[N/2],C[N/2],Dd[N/2]);
  return (int)(sink*0);
}
