// Review probe: per-second distribution of selected GPU Stats state channels (GPUDVDH, GPU_PPM, BSTGPUPH top state, GPUPH active%).
// usage: gpu_states <count>   build: xcrun clang -O1 -o gpu_states gpu_states.c -lIOReport -framework CoreFoundation
#include "ior.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char**argv){ int cnt=argc>1?atoi(argv[1]):5; CFDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("GPU Stats"),NULL,0,0,0);
  CFMutableDictionaryRef m=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,ch); CFMutableDictionaryRef sc=NULL; IOReportSubscriptionRef s=IOReportCreateSubscription(NULL,m,&sc,0,NULL);
  CFDictionaryRef p=IOReportCreateSamples(s,sc,NULL);
  for(int i=0;i<cnt;i++){ sleep(1); CFDictionaryRef c=IOReportCreateSamples(s,sc,NULL); CFDictionaryRef d=IOReportCreateSamplesDelta(p,c,NULL); CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
    printf("[%d]",i);
    for(CFIndex j=0;j<CFArrayGetCount(a);j++){ CFDictionaryRef x=CFArrayGetValueAtIndex(a,j); char n[64]; cs(IOReportChannelGetChannelName(x),n,64);
      if(strcmp(n,"GPUDVDH")&&strcmp(n,"GPUPH")&&strcmp(n,"BSTGPUPH")&&strcmp(n,"GPU_PPM")) continue; int k=IOReportStateGetCount(x); double tot=0; for(int q=0;q<k;q++) tot+=IOReportStateGetResidency(x,q);
      printf(" %s{",n); for(int q=0;q<k;q++){ double r=IOReportStateGetResidency(x,q); if(tot>0&&r/tot>=0.02){ char sn[32]; cs(IOReportStateGetNameForIndex(x,q),sn,32); printf("%s:%.0f%% ",sn,100*r/tot);} } printf("}"); }
    printf("\n"); fflush(stdout); p=c; }
  return 0; }
