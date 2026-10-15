// em_list.c — 列出 IOReport "Energy Model" 组的全部通道（驱动名、子组、名称、单位、当前累计值）。只读。
#include <stdio.h>
#include "ioreport.h"
int main(void){
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
  if(!ch){ printf("no Energy Model group\n"); return 1; }
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  CFDictionaryRef s=IOReportCreateSamples(sub,subbed,NULL); CFArrayRef arr=CFDictionaryGetValue(s,CFSTR("IOReportChannels"));
  printf("channels=%ld\n",(long)CFArrayGetCount(arr));
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char n[128],u[32],d[128],sg[128];
    cfstr(IOReportChannelGetChannelName(c),n,128); cfstr(IOReportChannelGetUnitLabel(c),u,32); cfstr(IOReportChannelGetDriverName(c),d,128); cfstr(IOReportChannelGetSubGroup(c),sg,128);
    printf("%-28s unit=%-4s fmt=%d val=%lld drv=%s sg=%s\n",n,u,IOReportChannelGetFormat(c),IOReportSimpleGetIntegerValue(c,NULL),d,sg); }
  return 0; }
