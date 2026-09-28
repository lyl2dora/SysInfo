// Review probe: list every channel in IOReport group "GPU Stats" with format, unit, driver and state names.
// build: xcrun clang -O1 -o gpustats_legend gpustats_legend.c -lIOReport -framework CoreFoundation
#include "ior.h"
#include <stdio.h>
int main(void){ CFDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("GPU Stats"),NULL,0,0,0);
  CFMutableDictionaryRef m=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,ch); CFMutableDictionaryRef sc=NULL;
  IOReportSubscriptionRef s=IOReportCreateSubscription(NULL,m,&sc,0,NULL); CFDictionaryRef smp=IOReportCreateSamples(s,sc,NULL);
  CFArrayRef a=CFDictionaryGetValue(smp,CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(a);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); char sg[96],n[96],u[32],d[64]; cs(IOReportChannelGetSubGroup(c),sg,96); cs(IOReportChannelGetChannelName(c),n,96); cs(IOReportChannelGetUnitLabel(c),u,32); cs(IOReportChannelGetDriverName(c),d,64);
    int f=IOReportChannelGetFormat(c); printf("%s | %s | fmt=%d | unit=%s | %s",sg,n,f,u,d);
    if(f==2){ int k=IOReportStateGetCount(c); printf(" | %d states:",k); for(int j=0;j<k;j++){ char sn[64]; cs(IOReportStateGetNameForIndex(c,j),sn,64); printf(" %s",sn);} }
    else if(f==1) printf(" | value=%lld",(long long)IOReportSimpleGetIntegerValue(c,0));
    printf("\n"); }
  return 0; }
