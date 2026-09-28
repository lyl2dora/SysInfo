// ioreport_bw_probe.c - DRAM bandwidth candidates: IOReport groups "Bandwidth", "AMC Stats", "PMP0"/"DCS BW" (state histograms)
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int IOReportChannelGetFormat(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
extern void IOReportIterate(CFDictionaryRef, int (^)(CFDictionaryRef));
static void str(CFStringRef r, char*b, int n){ b[0]=0; if(r) CFStringGetCString(r,b,n,kCFStringEncodingUTF8); }
static void run(CFStringRef group, CFStringRef sub, const char*filter){
  CFDictionaryRef d = IOReportCopyChannelsInGroup(group, sub, 0,0,0);
  char g[128]; str(group,g,128);
  if(!d){ printf("[%s] CopyChannelsInGroup -> NULL\n",g); return; }
  CFArrayRef a = CFDictionaryGetValue(d, CFSTR("IOReportChannels")); printf("[%s] %ld channels in legend\n", g, a?CFArrayGetCount(a):-1L);
  CFMutableDictionaryRef md = CFDictionaryCreateMutableCopy(NULL,0,d), subbed=NULL;
  IOReportSubscriptionRef s = IOReportCreateSubscription(NULL, md, &subbed, 0, NULL);
  if(!s){ printf("[%s] IOReportCreateSubscription -> NULL (listing legend names)\n", g);
    for(long i=0;a&&i<CFArrayGetCount(a)&&i<12;i++){ char x[256],y[256]; CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); str(IOReportChannelGetSubGroup(c),x,256); str(IOReportChannelGetChannelName(c),y,256); printf("   legend: %s / %s fmt=%d\n",x,y,IOReportChannelGetFormat(c)); }
    return; }
  CFDictionaryRef s1 = IOReportCreateSamples(s, subbed, NULL); sleep(1); CFDictionaryRef s2 = IOReportCreateSamples(s, subbed, NULL);
  CFDictionaryRef dl = IOReportCreateSamplesDelta(s1, s2, NULL);
  __block int shown=0;
  IOReportIterate(dl, ^int(CFDictionaryRef c){ char sg[256], nm[256], u[64]; str(IOReportChannelGetSubGroup(c),sg,256); str(IOReportChannelGetChannelName(c),nm,256); str(IOReportChannelGetUnitLabel(c),u,64);
    if(filter && !strstr(sg,filter)) return 0; if(shown++>=20) return 0;
    int f = IOReportChannelGetFormat(c);
    if(f==2){ int n=IOReportStateGetCount(c); printf("  %s / %s (state, %d bins, unit=%s):", sg, nm, n, u); for(int i=0;i<n&&i<24;i++){ char sn[64]; str(IOReportStateGetNameForIndex(c,i),sn,64); int64_t r=IOReportStateGetResidency(c,i); if(r) printf(" %s=%lld",sn,(long long)r);} printf("\n"); }
    else printf("  %s / %s fmt=%d unit=%s delta1s=%lld\n", sg, nm, f, u, (long long)IOReportSimpleGetIntegerValue(c,0));
    return 0; });
}
int main(void){
  run(CFSTR("Bandwidth"), NULL, NULL);
  run(CFSTR("AMC Stats"), NULL, NULL);
  run(CFSTR("PMP0"), NULL, " BW");
  return 0;
}
