// Probe: IOReport PMP0 groups "Energy" and "Volt-Temp HM" (state-format channels) + "SoC Stats/Cluster Power States" - idle vs loaded
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdatomic.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static atomic_int stop_flag = 0;
static void* spin(void* a){ volatile double x=1; while(!atomic_load(&stop_flag)) x = x*1.0000001+0.5; return NULL; }
static void s(CFStringRef c, char* b, int n){ b[0]=0; if(c) CFStringGetCString(c,b,n,kCFStringEncodingUTF8); }
static void dump(CFDictionaryRef d){
  CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){
    CFDictionaryRef ch = CFArrayGetValueAtIndex(arr,i); char g[64], sg[64], nm[64], u[16];
    s(IOReportChannelGetGroup(ch),g,64); s(IOReportChannelGetSubGroup(ch),sg,64); s(IOReportChannelGetChannelName(ch),nm,64); s(IOReportChannelGetUnitLabel(ch),u,16);
    int f = IOReportChannelGetFormat(ch);
    printf("[%s/%s] %s fmt=%d unit=%s:", g, sg, nm, f, u);
    if(f==2){ int n=IOReportStateGetCount(ch); for(int k=0;k<n;k++){ char st[64]; s(IOReportStateGetNameForIndex(ch,k),st,64); long long r=IOReportStateGetResidency(ch,k); if(r) printf(" %s=%lld", st, r);} }
    else printf(" value=%lld", IOReportSimpleGetIntegerValue(ch,NULL));
    printf("\n");
  }
}
int main(){
  CFMutableDictionaryRef a = IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("Energy"),0,0,0);
  CFMutableDictionaryRef b = IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("Volt-Temp HM"),0,0,0);
  CFMutableDictionaryRef c = IOReportCopyChannelsInGroup(CFSTR("SoC Stats"), CFSTR("Cluster Power States"),0,0,0);
  printf("a=%p b=%p c=%p\n",a,b,c);
  IOReportMergeChannels(a,b,NULL); IOReportMergeChannels(a,c,NULL);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,a,&subbed,0,NULL);
  printf("sub=%p\n", sub); if(!sub) return 1;
  CFDictionaryRef s1 = IOReportCreateSamples(sub,subbed,NULL); sleep(1); CFDictionaryRef s2 = IOReportCreateSamples(sub,subbed,NULL);
  printf("\n=== ABSOLUTE sample (first) ===\n"); dump(s1);
  printf("\n=== IDLE delta 1s ===\n"); dump(IOReportCreateSamplesDelta(s1,s2,NULL));
  pthread_t th[18]; for(int i=0;i<18;i++) pthread_create(&th[i],NULL,spin,NULL); usleep(300000);
  CFDictionaryRef s3 = IOReportCreateSamples(sub,subbed,NULL); sleep(1); CFDictionaryRef s4 = IOReportCreateSamples(sub,subbed,NULL);
  atomic_store(&stop_flag,1); for(int i=0;i<18;i++) pthread_join(th[i],NULL);
  printf("\n=== LOADED delta 1s (18 threads) ===\n"); dump(IOReportCreateSamplesDelta(s3,s4,NULL));
  return 0;
}
