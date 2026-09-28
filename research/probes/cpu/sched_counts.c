// Probe: cheap scheduler counters: processor_set_statistics(PROCESSOR_SET_LOAD_INFO) task/thread counts;
// system-wide interrupt rate from IOReport "Interrupt Statistics (by index)" (sum of First Level Interrupt Handler Count deltas);
// context switches: sum of pti_csw over accessible processes (own uid only as normal user).
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <mach/mach.h>
#include <libproc.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static long long csw_sum(int* ok, int* fail){
  int pids[8192]; int n = proc_listallpids(pids, sizeof pids)/1; long long s=0; *ok=*fail=0;
  for(int i=0;i<n;i++){ struct proc_taskinfo ti; if(proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &ti, sizeof ti)==sizeof ti){ s+=ti.pti_csw; (*ok)++; } else (*fail)++; }
  return s;
}
int main(){
  processor_set_name_t pset; kern_return_t kr = processor_set_default(mach_host_self(), &pset);
  struct processor_set_load_info li; mach_msg_type_number_t c = PROCESSOR_SET_LOAD_INFO_COUNT;
  kern_return_t kr2 = processor_set_statistics(pset, PROCESSOR_SET_LOAD_INFO, (processor_set_info_t)&li, &c);
  printf("processor_set_default kr=%d processor_set_statistics kr=%d: task_count=%d thread_count=%d load_average=%.2f mach_factor=%.2f\n", kr, kr2, li.task_count, li.thread_count, li.load_average/1000.0, li.mach_factor/1000.0);
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"), NULL, 0,0,0);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  int ok1,f1,ok2,f2; long long c1 = csw_sum(&ok1,&f1);
  CFDictionaryRef s1 = IOReportCreateSamples(sub,subbed,NULL); sleep(1); CFDictionaryRef s2 = IOReportCreateSamples(sub,subbed,NULL);
  long long c2 = csw_sum(&ok2,&f2);
  CFDictionaryRef d = IOReportCreateSamplesDelta(s1,s2,NULL);
  CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels")); long long tot=0; int nsrc=0;
  char top[5][128]={{0}}; long long topv[5]={0};
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef x = CFArrayGetValueAtIndex(arr,i); char nm[128], sg[128];
    CFStringGetCString(IOReportChannelGetChannelName(x),nm,128,kCFStringEncodingUTF8); CFStringGetCString(IOReportChannelGetSubGroup(x),sg,128,kCFStringEncodingUTF8);
    if(!strstr(nm,"First Level Interrupt Handler Count")) continue; long long v = IOReportSimpleGetIntegerValue(x,NULL); tot+=v; nsrc++;
    for(int k=0;k<5;k++) if(v>topv[k]){ for(int j=4;j>k;j--){ topv[j]=topv[j-1]; strcpy(top[j],top[j-1]); } topv[k]=v; strcpy(top[k],sg); break; } }
  printf("IOReport interrupts: %d sources, total first-level interrupts in 1s = %lld/s; top:", nsrc, tot);
  for(int k=0;k<5;k++) printf(" [%s]=%lld", top[k], topv[k]); printf("\n");
  printf("context switches (sum pti_csw over %d accessible procs, %d inaccessible) = %lld/s\n", ok2, f2, c2-c1);
  return 0;
}
