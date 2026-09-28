// Probe: same 2s window: per-core busy% from host_processor_info ticks vs IOReport "CPU Core Performance States" non-IDLE/DOWN residency.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
static void ticks(unsigned* out){ natural_t n; processor_info_array_t info; mach_msg_type_number_t c; host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &c); memcpy(out, info, n*CPU_STATE_MAX*sizeof(int)); vm_deallocate(mach_task_self(), (vm_address_t)info, c*sizeof(int)); }
int main(){
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"),0,0,0);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  unsigned a[18*4], b[18*4]; ticks(a); CFDictionaryRef s1 = IOReportCreateSamples(sub,subbed,NULL); sleep(2); ticks(b); CFDictionaryRef s2 = IOReportCreateSamples(sub,subbed,NULL);
  CFArrayRef arr = CFDictionaryGetValue(IOReportCreateSamplesDelta(s1,s2,NULL), CFSTR("IOReportChannels"));
  printf("cpu  ticks-busy%%  ioreport-channel  active-residency%%\n");
  for(int i=0;i<18;i++){
    unsigned u=b[i*4+CPU_STATE_USER]-a[i*4+CPU_STATE_USER], s=b[i*4+CPU_STATE_SYSTEM]-a[i*4+CPU_STATE_SYSTEM], id=b[i*4+CPU_STATE_IDLE]-a[i*4+CPU_STATE_IDLE], n=b[i*4+CPU_STATE_NICE]-a[i*4+CPU_STATE_NICE];
    CFDictionaryRef c = CFArrayGetValueAtIndex(arr,i); char nm[32]; CFStringGetCString(IOReportChannelGetChannelName(c),nm,32,kCFStringEncodingUTF8);
    long long tot=0, act=0; for(int k=0;k<IOReportStateGetCount(c);k++){ char st[16]; CFStringGetCString(IOReportStateGetNameForIndex(c,k),st,16,kCFStringEncodingUTF8); long long r=IOReportStateGetResidency(c,k); tot+=r; if(strcmp(st,"IDLE")&&strcmp(st,"DOWN")) act+=r; }
    printf("cpu%-2d  %5.1f%%        %-8s          %5.1f%%\n", i, 100.0*(u+s+n)/(u+s+id+n), nm, tot?100.0*act/tot:0);
  }
  return 0;
}
