// Review probe: ane0/ave0/avd0 interrupt counts via a WHOLE-GROUP subscription to "Interrupt Statistics (by index)"
// (the original agent subscribed per-subgroup, which returns NULL for ane0). Also H11ANEIn CurrentPowerState.
// usage: ane_irq <count>   build: xcrun clang -O1 -o ane_irq ane_irq.c -lIOReport -framework IOKit -framework CoreFoundation
#include "ior.h"
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
static double now(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec+t.tv_usec/1e6; }
static int anePS(void){ io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("H11ANEIn")); if(!s) return -1; int v=-2;
  CFDictionaryRef pm=IORegistryEntryCreateCFProperty(s,CFSTR("IOPowerManagement"),kCFAllocatorDefault,0); if(pm){ CFNumberRef n=CFDictionaryGetValue(pm,CFSTR("CurrentPowerState")); if(n) CFNumberGetValue(n,kCFNumberIntType,&v); CFRelease(pm);} IOObjectRelease(s); return v; }
int main(int argc,char**argv){ int cnt=argc>1?atoi(argv[1]):5;
  CFDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"),NULL,0,0,0);
  CFMutableDictionaryRef m=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,ch); CFMutableDictionaryRef sc=NULL;
  IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,m,&sc,0,NULL); if(!sub){ printf("sub NULL\n"); return 1; }
  // list which ane0 channels are in the subscribed dictionary
  CFArrayRef sa=CFDictionaryGetValue(sc,CFSTR("IOReportChannels")); int nane=0; for(CFIndex i=0;i<CFArrayGetCount(sa);i++){ char sg[64]; cs(IOReportChannelGetSubGroup(CFArrayGetValueAtIndex(sa,i)),sg,64); if(!strncmp(sg,"ane0",4)) nane++; }
  printf("subscribed %ld channels, of which ane0*: %d\n",(long)CFArrayGetCount(sa),nane);
  CFDictionaryRef prev=IOReportCreateSamples(sub,sc,NULL); double pt=now();
  for(int i=0;i<cnt;i++){ sleep(1); CFDictionaryRef cur=IOReportCreateSamples(sub,sc,NULL); double t=now(); CFDictionaryRef d=IOReportCreateSamplesDelta(prev,cur,NULL);
    CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); double ane=0,ave=0,avd=0,apr=0; int anech=0;
    for(CFIndex j=0;j<CFArrayGetCount(a);j++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,j); char sg[64],n[96]; cs(IOReportChannelGetSubGroup(c),sg,64); cs(IOReportChannelGetChannelName(c),n,96);
      if(!strstr(n,"First Level Interrupt Handler Count")) continue; double v=(double)IOReportSimpleGetIntegerValue(c,0);
      if(!strncmp(sg,"ane0",4)){ ane+=v; anech++; } else if(!strncmp(sg,"ave0",4)) ave+=v; else if(!strncmp(sg,"avd0",4)) avd+=v; else if(!strncmp(sg,"apr0",4)) apr+=v; }
    printf("[%d] ANE_PS=%d  ane0 IRQ/s=%.0f (ch=%d)  ave0=%.0f  avd0=%.0f  apr0=%.0f\n",i,anePS(),ane/(t-pt),anech,ave/(t-pt),avd/(t-pt),apr/(t-pt)); fflush(stdout);
    CFRelease(d); CFRelease(prev); prev=cur; pt=t; }
  return 0; }
