// Probe: absolute (non-delta) values of Energy Model channels over time, and via different subscription styles
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static void s(CFStringRef c, char* b, int n){ b[0]=0; if(c) CFStringGetCString(c,b,n,kCFStringEncodingUTF8); }
static const char* want[] = {"CPU Energy","PCPU","MCPU0","MCPU1","PCPM","MCPM0","PACC_0","MCPU0_0","GPU0","DRAM0","AMCC0","DCS0","GPU Energy",NULL};
static void show(CFDictionaryRef smp){
  CFArrayRef arr = CFDictionaryGetValue(smp, CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){
    CFDictionaryRef ch = CFArrayGetValueAtIndex(arr,i); char g[64], nm[128];
    s(IOReportChannelGetGroup(ch),g,64); if(strcmp(g,"Energy Model")) continue;
    s(IOReportChannelGetChannelName(ch),nm,128);
    for(int k=0;want[k];k++) if(!strcmp(want[k],nm)){ int32_t err=0; long long v=IOReportSimpleGetIntegerValue(ch,&err); printf(" [%s]=%lld", want[k], v); (void)err; }
  }
  printf("\n");
}
int main(){
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0,0,0);
  CFMutableDictionaryRef subbed=NULL;
  IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  for(int i=0;i<(getenv("N")?atoi(getenv("N")):6);i++){ CFDictionaryRef smp = IOReportCreateSamples(sub,subbed,NULL); printf("t=%ds:", i); show(smp); CFRelease(smp); sleep(1); }
  // Print raw dictionary of one CPU channel for structure inspection
  CFDictionaryRef smp = IOReportCreateSamples(sub,subbed,NULL);
  CFArrayRef arr = CFDictionaryGetValue(smp, CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c = CFArrayGetValueAtIndex(arr,i); char nm[128]; s(IOReportChannelGetChannelName(c),nm,128);
    if(!strcmp(nm,"CPU Energy")||!strcmp(nm,"GPU Energy")){ printf("--- raw %s ---\n", nm); CFShow(c); } }
  return 0;
}
