// Independent read-only check: does IOReport "Energy Model" advance at 1 s cadence on macOS 27?
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
typedef struct __IOReportSubscriptionCF *IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
static void dump(CFDictionaryRef delta, double dt){
  CFArrayRef arr = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
  if(!arr){printf("  no channels\n");return;}
  long n=CFArrayGetCount(arr); int shown=0; long nonzero=0;
  for(long i=0;i<n;i++){
    CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i);
    char name[128]="?",unit[32]="?";
    CFStringRef cn=IOReportChannelGetChannelName(ch); if(cn) CFStringGetCString(cn,name,sizeof name,kCFStringEncodingUTF8);
    CFStringRef u=IOReportChannelGetUnitLabel(ch); if(u) CFStringGetCString(u,unit,sizeof unit,kCFStringEncodingUTF8);
    int64_t v=IOReportSimpleGetIntegerValue(ch,NULL);
    if(v!=0) nonzero++;
    if(strstr(name,"CPU Energy")||strstr(name,"GPU Energy")||!strcmp(name,"PCPU")||!strcmp(name,"MCPU0")||!strcmp(name,"DRAM0")||!strcmp(name,"GPU0")||!strcmp(name,"ANE0")){
      printf("  %-14s delta=%lld %s over %.2fs\n",name,(long long)v,unit,dt); shown++;}
  }
  printf("  channels=%ld nonzero_deltas=%ld\n",n,nonzero);
}
int main(void){
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
  if(!ch){printf("no Energy Model group\n");return 1;}
  CFMutableDictionaryRef subbed=NULL;
  IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  if(!sub){printf("subscription failed\n");return 1;}
  CFDictionaryRef prev=IOReportCreateSamples(sub,subbed,NULL);
  for(int i=0;i<4;i++){
    // light CPU load in second half to see whether counters react
    double t0=CFAbsoluteTimeGetCurrent();
    if(i>=2){ volatile double x=0; while(CFAbsoluteTimeGetCurrent()-t0<1.0){ for(int k=0;k<100000;k++) x+=k*0.5; } }
    else sleep(1);
    CFDictionaryRef cur=IOReportCreateSamples(sub,subbed,NULL);
    double dt=CFAbsoluteTimeGetCurrent()-t0;
    CFDictionaryRef d=IOReportCreateSamplesDelta(prev,cur,NULL);
    printf("sample %d (%s):\n",i,i>=2?"1 thread busy":"idle"); dump(d,dt);
    CFRelease(d); CFRelease(prev); prev=cur;
  }
  return 0;
}
