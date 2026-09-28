// Review probe: absolute values of the NON-PMGR Energy Model channels (PCIe/apciec uJ, AGX GPU Energy nJ) 10 s apart, to check
// whether Stats' "PCI Power" source is frozen like the PMGR channels or simply zero/live. Read-only.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
int main(){
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0); CFMutableDictionaryRef sd=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sd,0,NULL);
  CFDictionaryRef s[2]; s[0]=IOReportCreateSamples(sub,sd,NULL); sleep(10); s[1]=IOReportCreateSamples(sub,sd,NULL);
  CFArrayRef a0=CFDictionaryGetValue(s[0],CFSTR("IOReportChannels")), a1=CFDictionaryGetValue(s[1],CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(a0);i++){ char n[64],u[16]; CFDictionaryRef c0=CFArrayGetValueAtIndex(a0,i), c1=CFArrayGetValueAtIndex(a1,i);
    CFStringGetCString(IOReportChannelGetChannelName(c0),n,64,kCFStringEncodingUTF8); CFStringGetCString(IOReportChannelGetUnitLabel(c0),u,16,kCFStringEncodingUTF8);
    if(strstr(n,"PCI")||strstr(n,"apciec")||!strcmp(n,"GPU Energy")||!strcmp(n,"CPU Energy")||!strcmp(n,"ANE0")||!strcmp(n,"DRAM0")){ long long v0=IOReportSimpleGetIntegerValue(c0,NULL), v1=IOReportSimpleGetIntegerValue(c1,NULL);
      printf("%-20s %-3s t0=%lld t10=%lld delta=%lld\n", n, u, v0, v1, v1-v0); } }
  return 0;
}
