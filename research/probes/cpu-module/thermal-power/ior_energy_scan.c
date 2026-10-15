// ior_energy_scan.c — 扫描全部 IOReport 通道，找出「单位是能量（mJ/uJ/nJ）或名字含 Energy/Power」且在 2 s 内有变化的通道（= 实时能量源候选）。
// 用于回答：Energy Model 之外，本机还有没有逐秒更新的 CPU 能量计数。只读。用法：ior_energy_scan [间隔秒=2]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "ioreport.h"
CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
int main(int argc,char**argv){
  double iv=argc>1?atof(argv[1]):2;
  CFMutableDictionaryRef ch=IOReportCopyAllChannels(0,0); if(!ch){ printf("CopyAllChannels failed\n"); return 1; }
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  CFDictionaryRef a=IOReportCreateSamples(sub,subbed,NULL); usleep((useconds_t)(iv*1e6)); CFDictionaryRef b=IOReportCreateSamples(sub,subbed,NULL);
  CFDictionaryRef d=IOReportCreateSamplesDelta(a,b,NULL); CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
  long n=CFArrayGetCount(arr), hits=0; printf("total channels=%ld\n",n);
  for(CFIndex i=0;i<n;i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char g[96],sg[96],nm[96],u[24];
    cfstr(IOReportChannelGetGroup(c),g,96); cfstr(IOReportChannelGetSubGroup(c),sg,96); cfstr(IOReportChannelGetChannelName(c),nm,96); cfstr(IOReportChannelGetUnitLabel(c),u,24);
    int fmt=IOReportChannelGetFormat(c); int energy = !strcmp(u,"mJ")||!strcmp(u,"uJ")||!strcmp(u,"nJ")||strstr(nm,"Energy")||strstr(nm,"Power")||strstr(sg,"Energy")||strstr(sg,"Power");
    if(!energy || fmt!=1) continue; int64_t v=IOReportSimpleGetIntegerValue(c,NULL); if(v==0) continue; hits++;
    printf("  [%s | %s] %-28s %s delta=%lld (%.3f W if %s)\n",g,sg,nm,u,(long long)v, !strcmp(u,"mJ")? v/1e3/iv : !strcmp(u,"uJ")? v/1e6/iv : !strcmp(u,"nJ")? v/1e9/iv : 0.0, u); }
  printf("changing energy-like simple channels: %ld\n",hits); return 0; }
