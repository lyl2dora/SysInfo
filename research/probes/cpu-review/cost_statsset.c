// Review probe: IOReportCreateSamples cost for EXACTLY Stats' FrequencyReader channel set (CPU Complex Performance States + CPU Core
// Performance States merged, 27 channels) vs the whole "CPU Stats" group, vs Core-only. 200 iterations, thread CPU time.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <time.h>
#include <mach/mach_time.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
static double cpu_us(){ return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)/1000.0; }
static double wall_us(){ return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000.0; }
static void bench(const char* name, CFMutableDictionaryRef ch){
  CFArrayRef a = CFDictionaryGetValue(ch, CFSTR("IOReportChannels")); long n = a? CFArrayGetCount(a):-1;
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  double c0=cpu_us(), w0=wall_us(); for(int i=0;i<200;i++){ CFDictionaryRef s=IOReportCreateSamples(sub,subbed,NULL); CFRelease(s);} 
  printf("%-55s channels=%3ld  %.0f us/call wall, %.0f us/call thread CPU\n", name, n, (wall_us()-w0)/200, (cpu_us()-c0)/200);
}
int main(){
  CFMutableDictionaryRef a = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"),0,0,0);
  CFMutableDictionaryRef b = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"),0,0,0);
  IOReportMergeChannels(a,b,NULL);
  bench("Stats set: Complex Perf States + Core Perf States", a);
  bench("Core Perf States only", IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"),0,0,0));
  bench("whole CPU Stats group", IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), NULL,0,0,0));
  bench("Interrupt Statistics (by index)", IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"), NULL,0,0,0));
  bench("GPU Stats", IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), NULL,0,0,0));
  return 0;
}
