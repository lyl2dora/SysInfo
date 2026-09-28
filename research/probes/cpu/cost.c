// Probe: per-call cost of the sampling primitives (wall time, 200 iterations each)
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <time.h>
static double cpu_us(){ return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)/1000.0; }
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
static double us(uint64_t d){ mach_timebase_info_data_t tb; mach_timebase_info(&tb); return d*tb.numer/(double)tb.denom/1000.0; }
static void bench(const char* name, CFStringRef g, CFStringRef sg){
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(g, sg, 0,0,0); CFMutableDictionaryRef subbed=NULL;
  IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  double c0=cpu_us(); uint64_t t=mach_absolute_time(); for(int i=0;i<200;i++){ CFDictionaryRef s=IOReportCreateSamples(sub,subbed,NULL); CFRelease(s);} 
  printf("IOReportCreateSamples[%s]: %.1f us/call wall, %.1f us/call thread CPU\n", name, us(mach_absolute_time()-t)/200, (cpu_us()-c0)/200);
}
int main(){
  bench("CPU Stats (all 3 subgroups)", CFSTR("CPU Stats"), NULL);
  bench("Energy Model (364 ch)", CFSTR("Energy Model"), NULL);
  bench("PMP0/Energy", CFSTR("PMP0"), CFSTR("Energy"));
  uint64_t t=mach_absolute_time(); for(int i=0;i<200;i++){ natural_t n; processor_info_array_t info; mach_msg_type_number_t c; host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &c); vm_deallocate(mach_task_self(), (vm_address_t)info, c*sizeof(int)); }
  printf("host_processor_info(PROCESSOR_CPU_LOAD_INFO): %.1f us/call\n", us(mach_absolute_time()-t)/200);
  int pids[8192]; t=mach_absolute_time(); int n=0, ok=0; for(int i=0;i<20;i++){ n=proc_listallpids(pids,sizeof pids); ok=0; for(int j=0;j<n;j++){ struct rusage_info_v6 r; if(proc_pid_rusage(pids[j], RUSAGE_INFO_V6, (rusage_info_t*)&r)==0) ok++; } }
  printf("full libproc sweep (proc_listallpids + proc_pid_rusage x %d pids, %d ok): %.2f ms/sweep\n", n, ok, us(mach_absolute_time()-t)/20/1000);
  return 0;
}
