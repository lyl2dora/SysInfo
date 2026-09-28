// Review probe: check GPUPH residency units: sum of all state residencies per delta vs 24 MHz * wall seconds.
// build: xcrun clang -O1 -o gpuph_ticks gpuph_ticks.c -lIOReport -framework CoreFoundation
#include "ior.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
static double now(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec+t.tv_usec/1e6; }
int main(void){ CFDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("GPU Stats"),CFSTR("GPU Performance States"),0,0,0);
  CFMutableDictionaryRef m=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,ch); CFMutableDictionaryRef sc=NULL; IOReportSubscriptionRef s=IOReportCreateSubscription(NULL,m,&sc,0,NULL);
  CFDictionaryRef p=IOReportCreateSamples(s,sc,NULL); double t0=now();
  for(int i=0;i<3;i++){ sleep(2); CFDictionaryRef c=IOReportCreateSamples(s,sc,NULL); double t1=now(); CFDictionaryRef d=IOReportCreateSamplesDelta(p,c,NULL);
    CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
    for(CFIndex j=0;j<CFArrayGetCount(a);j++){ CFDictionaryRef x=CFArrayGetValueAtIndex(a,j); char n[64]; cs(IOReportChannelGetChannelName(x),n,64); double tot=0; for(int k=0;k<IOReportStateGetCount(x);k++) tot+=IOReportStateGetResidency(x,k);
      printf("%s: residency sum=%.0f ticks over %.3fs -> %.4f x 24MHz\n",n,tot,t1-t0,tot/(24e6*(t1-t0))); }
    p=c; t0=t1; }
  return 0; }
