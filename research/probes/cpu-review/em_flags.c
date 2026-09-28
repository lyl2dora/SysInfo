// Review probe: is the frozen Energy Model a subscription artefact? Try IOReportCreateSubscription flags 0,1,2,4,8,16,32 and a
// fresh IOReportCopyChannelsInGroup each time; under 18-thread load for 2 s check whether "CPU Energy"/"MCPU0"/"PCPU" move. Read-only.
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
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static atomic_int stop_flag=0; static void* spin(void* a){ volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
static long long get(CFDictionaryRef s, const char* want){ CFArrayRef arr=CFDictionaryGetValue(s,CFSTR("IOReportChannels")); for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char n[64]; CFStringGetCString(IOReportChannelGetChannelName(c),n,64,kCFStringEncodingUTF8); if(!strcmp(n,want)) return IOReportSimpleGetIntegerValue(c,NULL);} return -1; }
int main(){
  pthread_t th[18]; for(int i=0;i<18;i++) pthread_create(&th[i],NULL,spin,NULL);
  uint64_t flags[]={0,1,2,4,8,16,32};
  for(int f=0;f<7;f++){
    CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0); CFMutableDictionaryRef sd=NULL;
    IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sd,flags[f],NULL);
    if(!sub){ printf("flags=%llu: subscription NULL\n", flags[f]); continue; }
    CFDictionaryRef a=IOReportCreateSamples(sub,sd,NULL); sleep(2); CFDictionaryRef b=IOReportCreateSamples(sub,sd,NULL);
    printf("flags=%-3llu under 18-thread load 2s: CPU Energy %lld -> %lld (d=%lld)  PCPU d=%lld  MCPU0 d=%lld  GPU Energy(AGX) d=%lld nJ\n", flags[f], get(a,"CPU Energy"), get(b,"CPU Energy"), get(b,"CPU Energy")-get(a,"CPU Energy"), get(b,"PCPU")-get(a,"PCPU"), get(b,"MCPU0")-get(a,"MCPU0"), get(b,"GPU Energy")-get(a,"GPU Energy"));
    fflush(stdout); CFRelease(a); CFRelease(b);
  }
  atomic_store(&stop_flag,1); for(int i=0;i<18;i++) pthread_join(th[i],NULL); return 0;
}
