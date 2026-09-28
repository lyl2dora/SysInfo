// Probe: over a 5s window with load, count Energy Model channels (incl. DTL) whose value changed, per driver.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static atomic_int stop_flag=0; static void* spin(void* a){ volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
int main(){
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0,0,0);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  pthread_t th[18]; for(int i=0;i<18;i++) pthread_create(&th[i],NULL,spin,NULL);
  CFDictionaryRef s1 = IOReportCreateSamples(sub,subbed,NULL); sleep(5); CFDictionaryRef s2 = IOReportCreateSamples(sub,subbed,NULL);
  atomic_store(&stop_flag,1); for(int i=0;i<18;i++) pthread_join(th[i],NULL);
  CFArrayRef arr = CFDictionaryGetValue(IOReportCreateSamplesDelta(s1,s2,NULL), CFSTR("IOReportChannels"));
  int total=0, changed=0, pmgrTotal=0, pmgrChanged=0;
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c = CFArrayGetValueAtIndex(arr,i); char d[128], n[128];
    CFStringGetCString(IOReportChannelGetDriverName(c),d,128,kCFStringEncodingUTF8); CFStringGetCString(IOReportChannelGetChannelName(c),n,128,kCFStringEncodingUTF8);
    long long v = IOReportSimpleGetIntegerValue(c,NULL); total++; if(v) { changed++; printf("changed: %s [%s] delta=%lld\n", n, d, v); }
    if(strstr(d,"PMGR")){ pmgrTotal++; if(v) pmgrChanged++; } }
  printf("Energy Model under 18-thread load, 5s: %d channels, %d changed; PMGR-driver channels %d, changed %d\n", total, changed, pmgrTotal, pmgrChanged);
  return 0;
}
