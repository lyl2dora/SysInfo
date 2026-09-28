// Probe: IOReport "Energy Model" group -> CPU/cluster/core power (mJ deltas / dt), idle vs loaded
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static atomic_int stop_flag = 0;
static void* spin(void* a){ volatile double x=1; while(!atomic_load(&stop_flag)) x = x*1.0000001+0.5; return NULL; }
static void s(CFStringRef c, char* b, int n){ b[0]=0; if(c) CFStringGetCString(c,b,n,kCFStringEncodingUTF8); }
static double now(){ static mach_timebase_info_data_t tb; if(!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time()*tb.numer/tb.denom/1e9; }
static double toJ(const char* u, int64_t v){ if(!strcmp(u,"mJ")) return v/1e3; if(!strcmp(u,"uJ")) return v/1e6; if(!strcmp(u,"nJ")) return v/1e9; return v; }
static void dump(CFDictionaryRef d, double dt, int all){
  CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
  double sumCores=0, sumCPM=0;
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){
    CFDictionaryRef ch = CFArrayGetValueAtIndex(arr,i);
    char nm[128], u[16]; s(IOReportChannelGetChannelName(ch),nm,128); s(IOReportChannelGetUnitLabel(ch),u,16);
    int64_t v = IOReportSimpleGetIntegerValue(ch, NULL);
    if(strstr(nm,"DTL")) continue;
    double w = toJ(u,v)/dt;
    if(all || v) printf("  %-18s %10lld %s  => %8.3f W\n", nm, v, u, w);
    if(!strcmp(nm,"MCPU0")||!strcmp(nm,"MCPU1")||!strcmp(nm,"PCPU")) sumCores+=w;
    if(!strcmp(nm,"MCPM0")||!strcmp(nm,"MCPM1")||!strcmp(nm,"PCPM")) sumCPM+=w;
  }
  printf("  sum(MCPU0+MCPU1+PCPU)=%.3f W  sum(MCPM0+MCPM1+PCPM)=%.3f W\n", sumCores, sumCPM);
}
int main(int argc, char** argv){
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0,0,0);
  CFMutableDictionaryRef subbed=NULL;
  IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  printf("channels=%p subscription=%p\n", ch, sub); if(!sub) return 1;
  double t1=now(); CFDictionaryRef s1 = IOReportCreateSamples(sub,subbed,NULL); sleep(1);
  double t2=now(); CFDictionaryRef s2 = IOReportCreateSamples(sub,subbed,NULL);
  printf("\n=== IDLE %.3fs ===\n", t2-t1); dump(IOReportCreateSamplesDelta(s1,s2,NULL), t2-t1, 1);
  int n = argc>1?atoi(argv[1]):18; pthread_t th[64]; for(int i=0;i<n;i++) pthread_create(&th[i],NULL,spin,NULL);
  usleep(300000);
  double t3=now(); CFDictionaryRef s3 = IOReportCreateSamples(sub,subbed,NULL); sleep(1);
  double t4=now(); CFDictionaryRef s4 = IOReportCreateSamples(sub,subbed,NULL);
  atomic_store(&stop_flag,1); for(int i=0;i<n;i++) pthread_join(th[i],NULL);
  printf("\n=== LOADED (%d threads) %.3fs ===\n", n, t4-t3); dump(IOReportCreateSamplesDelta(s3,s4,NULL), t4-t3, 0);
  return 0;
}
