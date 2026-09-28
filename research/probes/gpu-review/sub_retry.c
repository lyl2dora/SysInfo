// Review probe: retry the subscriptions the original agent reported as refused (ane0 IRQ stats, AMC Stats Perf Counters)
// using different construction methods: (1) group+subgroup, (2) group only, (3) IOReportCopyAllChannels filtered to the channels,
// (4) one channel at a time. Reports NULL/non-NULL and two-sample deltas.
// build: xcrun clang -O1 -o sub_retry sub_retry.c -lIOReport -framework CoreFoundation
#include "ior.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void try_sub(const char*label, CFDictionaryRef ch){
  if(!ch){ printf("%-60s channels=NULL\n",label); return; }
  CFArrayRef a=CFDictionaryGetValue(ch,CFSTR("IOReportChannels")); CFIndex n=a?CFArrayGetCount(a):0;
  CFMutableDictionaryRef m=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,ch); CFMutableDictionaryRef sc=NULL;
  IOReportSubscriptionRef s=IOReportCreateSubscription(NULL,m,&sc,0,NULL);
  printf("%-60s nch=%ld sub=%s",label,(long)n,s?"OK":"NULL");
  if(s){ CFArrayRef sa=CFDictionaryGetValue(sc,CFSTR("IOReportChannels")); printf(" subscribed=%ld",sa?(long)CFArrayGetCount(sa):0L);
    CFDictionaryRef p=IOReportCreateSamples(s,sc,NULL); sleep(1); CFDictionaryRef c=IOReportCreateSamples(s,sc,NULL); CFDictionaryRef d=IOReportCreateSamplesDelta(p,c,NULL);
    CFArrayRef da=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); int nz=0; for(CFIndex i=0;i<CFArrayGetCount(da);i++){ CFDictionaryRef x=CFArrayGetValueAtIndex(da,i); if(IOReportChannelGetFormat(x)==1 && IOReportSimpleGetIntegerValue(x,0)!=0){ nz++; if(nz<=4){ char nm[96]; cs(IOReportChannelGetChannelName(x),nm,96); printf(" [%s=%lld]",nm,(long long)IOReportSimpleGetIntegerValue(x,0)); } } }
    printf(" nonzero-deltas=%d",nz); }
  printf("\n"); }
static CFDictionaryRef filter_all(const char*group,const char*subprefix,const char*namesub){
  CFDictionaryRef all=IOReportCopyAllChannels(0,0); CFArrayRef a=CFDictionaryGetValue(all,CFSTR("IOReportChannels"));
  CFMutableArrayRef out=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks); char drv[64]="";
  for(CFIndex i=0;i<CFArrayGetCount(a);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); char g[96],sg[96],n[96]; cs(IOReportChannelGetGroup(c),g,96); cs(IOReportChannelGetSubGroup(c),sg,96); cs(IOReportChannelGetChannelName(c),n,96);
    if(!strcmp(g,group) && (!subprefix||!strncmp(sg,subprefix,strlen(subprefix))) && (!namesub||strstr(n,namesub))){ CFArrayAppendValue(out,c); if(!drv[0]) cs(IOReportChannelGetDriverName(c),drv,64);} }
  printf("  (filtered %ld channels from CopyAllChannels for %s/%s*; driver=%s)\n",(long)CFArrayGetCount(out),group,subprefix?subprefix:"",drv);
  const void*k[]={CFSTR("IOReportChannels")}; const void*v[]={out}; return CFDictionaryCreate(NULL,k,v,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks); }
int main(void){
  printf("== ane0 interrupt statistics\n");
  try_sub("IRQ group+subgroup 'ane0 0'", IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"),CFSTR("ane0 0"),0,0,0));
  try_sub("IRQ group+subgroup 'ave0 0' (control)", IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"),CFSTR("ave0 0"),0,0,0));
  try_sub("CopyAllChannels filtered IRQ 'ane0'", filter_all("Interrupt Statistics (by index)","ane0",NULL));
  try_sub("IRQ whole group (all subgroups)", IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"),NULL,0,0,0));
  printf("== AMC Stats\n");
  try_sub("AMC Stats / Perf Counters", IOReportCopyChannelsInGroup(CFSTR("AMC Stats"),CFSTR("Perf Counters"),0,0,0));
  try_sub("AMC Stats (whole group)", IOReportCopyChannelsInGroup(CFSTR("AMC Stats"),NULL,0,0,0));
  try_sub("CopyAllChannels filtered AMC Stats 'GFX'", filter_all("AMC Stats",NULL,"GFX"));
  return 0; }
