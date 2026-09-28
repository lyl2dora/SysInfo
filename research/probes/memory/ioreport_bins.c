// ioreport_bins.c - print all bin names of PMP0 "DCS BW / AMCC RD+WR" state channel
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
extern void IOReportIterate(CFDictionaryRef, int (^)(CFDictionaryRef));
int main(void){
  CFDictionaryRef d = IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("DCS BW"), 0,0,0);
  CFMutableDictionaryRef md = CFDictionaryCreateMutableCopy(NULL,0,d), sub=NULL;
  IOReportSubscriptionRef s = IOReportCreateSubscription(NULL, md, &sub, 0, NULL);
  CFDictionaryRef smp = IOReportCreateSamples(s, sub, NULL);
  IOReportIterate(smp, ^int(CFDictionaryRef c){ char nm[128]; CFStringGetCString(IOReportChannelGetChannelName(c),nm,128,kCFStringEncodingUTF8);
    int n=IOReportStateGetCount(c); printf("%s (%d bins, cumulative since boot):",nm,n);
    for(int i=0;i<n;i++){ char b[64]={0}; CFStringRef bn=IOReportStateGetNameForIndex(c,i); if(bn) CFStringGetCString(bn,b,64,kCFStringEncodingUTF8); printf(" [%s]=%lld",b,(long long)IOReportStateGetResidency(c,i)); }
    printf("\n"); return 0; });
  return 0;
}
