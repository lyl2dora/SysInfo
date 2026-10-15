// sk_em_watch.c — 独立复核「Energy Model（PMGR）按 1800 s 批量发布、逐秒只有 AGX GPU Energy 在变」。只读。
// 每 dt 秒对整组 Energy Model 采样一次，打印：墙钟、本次有变化的通道数、变化通道里能量最大的前 6 个（J）、CPU 类通道合计（J）。
// 用法：sk_em_watch <总秒数> [间隔秒=1]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include "sk_ior.h"
typedef struct { char n[64]; double j; } Top;
int main(int argc,char**argv){
  int total=argc>1?atoi(argv[1]):60; double iv=argc>2?atof(argv[2]):1;
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
  if(!ch){ printf("no Energy Model\n"); return 1; }
  CFMutableDictionaryRef sd=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sd,0,NULL);
  CFDictionaryRef prev=IOReportCreateSamples(sub,sd,NULL);
  int nsteps=(int)(total/iv);
  for(int s=0;s<nsteps;s++){
    usleep((useconds_t)(iv*1e6));
    CFDictionaryRef cur=IOReportCreateSamples(sub,sd,NULL); CFDictionaryRef d=IOReportCreateSamplesDelta(prev,cur,NULL);
    CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); long n=CFArrayGetCount(a); int changed=0; double cpuJ=0; Top top[6]={0};
    for(CFIndex i=0;i<n;i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); int64_t v=IOReportSimpleGetIntegerValue(c,NULL); if(!v) continue; changed++;
      char nm[64],u[16]; sk_cf(IOReportChannelGetChannelName(c),nm,64); sk_cf(IOReportChannelGetUnitLabel(c),u,16); double j=v*sk_unit_to_J(u);
      if(!strcmp(nm,"CPU Energy")) cpuJ=j;
      for(int t=0;t<6;t++) if(j>top[t].j){ memmove(&top[t+1],&top[t],sizeof(Top)*(5-t)); strncpy(top[t].n,nm,63); top[t].j=j; break; } }
    time_t now=time(NULL); struct tm tm; localtime_r(&now,&tm); char ts[16]; strftime(ts,16,"%H:%M:%S",&tm);
    printf("%s ch=%ld changed=%d CPU_Energy=%.3fJ top:",ts,n,changed,cpuJ); for(int t=0;t<6&&top[t].j>0;t++) printf(" %s=%.3f",top[t].n,top[t].j); printf("\n"); fflush(stdout);
    CFRelease(d); CFRelease(prev); prev=cur; }
  return 0; }
