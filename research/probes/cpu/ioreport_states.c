// Probe: dump IOReport "CPU Stats" state channels: state names + residency deltas over 1s (idle, then under load)
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
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
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
static atomic_int stop_flag = 0;
static void* spin(void* a){ volatile double x=1; while(!atomic_load(&stop_flag)) x = x*1.0000001+0.5; return NULL; }
static void s(CFStringRef c, char* b, int n){ b[0]=0; if(c) CFStringGetCString(c,b,n,kCFStringEncodingUTF8); }
static void dump(CFDictionaryRef delta, int verbose){
  CFArrayRef arr = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){
    CFDictionaryRef ch = CFArrayGetValueAtIndex(arr,i);
    char sg[128], nm[128]; s(IOReportChannelGetSubGroup(ch),sg,128); s(IOReportChannelGetChannelName(ch),nm,128);
    int n = IOReportStateGetCount(ch);
    int64_t tot=0, active=0; for(int k=0;k<n;k++){ int64_t r=IOReportStateGetResidency(ch,k); tot+=r; char st[64]; s(IOReportStateGetNameForIndex(ch,k),st,64); if(strcmp(st,"IDLE")&&strcmp(st,"DOWN")&&strcmp(st,"OFF")) active+=r; }
    printf("[%s] %-11s states=%2d total=%lld ticks(%.3fs@24MHz) active=%.1f%% :", sg, nm, n, tot, tot/24e6, tot? 100.0*active/tot:0);
    for(int k=0;k<n;k++){ char st[64]; s(IOReportStateGetNameForIndex(ch,k),st,64); int64_t r=IOReportStateGetResidency(ch,k); if(verbose || r) printf(" %s=%lld", st, r); }
    printf("\n");
  }
}
int main(int argc, char** argv){
  CFMutableDictionaryRef a = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"),0,0,0);
  CFMutableDictionaryRef b = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"),0,0,0);
  CFMutableDictionaryRef c = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Complex Voltage States"),0,0,0);
  printf("copy channels: complex=%p core=%p voltage=%p\n", a,b,c);
  IOReportMergeChannels(a,b,NULL); IOReportMergeChannels(a,c,NULL);
  CFMutableDictionaryRef subbed=NULL;
  IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,a,&subbed,0,NULL);
  printf("subscription=%p\n", sub); if(!sub) return 1;
  // print all state names once (verbose) from an idle 1s delta
  CFDictionaryRef s1 = IOReportCreateSamples(sub,subbed,NULL); sleep(1);
  CFDictionaryRef s2 = IOReportCreateSamples(sub,subbed,NULL);
  CFDictionaryRef d = IOReportCreateSamplesDelta(s1,s2,NULL);
  printf("\n=== IDLE 1s (verbose state list) ===\n"); dump(d,1);
  // loaded phase: spin 18 threads
  int nthreads = argc>1 ? atoi(argv[1]) : 18; pthread_t th[64];
  for(int i=0;i<nthreads;i++) pthread_create(&th[i],NULL,spin,NULL);
  usleep(200000);
  CFDictionaryRef s3 = IOReportCreateSamples(sub,subbed,NULL); sleep(1);
  CFDictionaryRef s4 = IOReportCreateSamples(sub,subbed,NULL);
  atomic_store(&stop_flag,1); for(int i=0;i<nthreads;i++) pthread_join(th[i],NULL);
  CFDictionaryRef d2 = IOReportCreateSamplesDelta(s3,s4,NULL);
  printf("\n=== LOADED 1s (%d spinning threads; non-zero states only) ===\n", nthreads); dump(d2,0);
  return 0;
}
