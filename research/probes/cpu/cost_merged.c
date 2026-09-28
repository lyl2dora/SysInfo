// Probe: cost of ONE merged IOReport subscription (CPU Stats + Energy Model + PMP0/Energy + PMP0/Volt-Temp HM) vs separate
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <time.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
static double cpu_us(){ return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)/1000.0; }
static double wall_us(){ return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000.0; }
int main(){
  CFMutableDictionaryRef a = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), NULL,0,0,0);
  IOReportMergeChannels(a, IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL,0,0,0), NULL);
  IOReportMergeChannels(a, IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("Energy"),0,0,0), NULL);
  IOReportMergeChannels(a, IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("Volt-Temp HM"),0,0,0), NULL);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,a,&subbed,0,NULL);
  double c0=cpu_us(), w0=wall_us(); for(int i=0;i<100;i++){ CFDictionaryRef s=IOReportCreateSamples(sub,subbed,NULL); CFRelease(s);} 
  printf("merged subscription (CPU Stats+Energy Model+PMP0 Energy+Volt-Temp): %.1f us wall, %.1f us CPU per sample\n", (wall_us()-w0)/100, (cpu_us()-c0)/100);
  return 0;
}
