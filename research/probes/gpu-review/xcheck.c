// Review probe: 1 Hz cross-check of GPU metrics from independent sources.
//  - IOAccelerator PerformanceStatistics Device/Renderer Utilization % (Stats' source)
//  - IOReport GPU Stats/GPU Performance States (GPUPH): active% + avg MHz (index -> pmgr voltage-states9, Hz)
//  - IOReport Energy Model "GPU Energy" (AGX, nJ) -> W
//  - SMC (read-only) PSTR (system total W), PDTR (DC-in W), PMVC, PHPC, mean/max of all Tg* keys
// usage: xcheck <seconds> [intervalSec]
// build: xcrun clang -O1 -o xcheck xcheck.c -lIOReport -framework IOKit -framework CoreFoundation
#include "ior.h"
#include "smc.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
static double now(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec+t.tv_usec/1e6; }
static double tbl[32]; static int ntbl=0;
static void load_table(void){
  io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("AppleARMIODevice"),&it);
  io_object_t e; while((e=IOIteratorNext(it))){ io_name_t n; IORegistryEntryGetName(e,n);
    if(!strcmp(n,"pmgr")){ CFDataRef d=IORegistryEntryCreateCFProperty(e,CFSTR("voltage-states9"),kCFAllocatorDefault,0);
      if(d){ const uint32_t*p=(const uint32_t*)CFDataGetBytePtr(d); ntbl=(int)CFDataGetLength(d)/8; for(int i=0;i<ntbl&&i<32;i++) tbl[i]=p[i*2]/1e6; CFRelease(d);} }
    IOObjectRelease(e);} IOObjectRelease(it); }
static int perfstat(const char*key){
  io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOAccelerator")); if(!s) return -1;
  CFDictionaryRef ps=IORegistryEntryCreateCFProperty(s,CFSTR("PerformanceStatistics"),kCFAllocatorDefault,0); IOObjectRelease(s); if(!ps) return -2;
  CFStringRef k=CFStringCreateWithCString(NULL,key,kCFStringEncodingUTF8); CFNumberRef v=CFDictionaryGetValue(ps,k); int r=-3; if(v) CFNumberGetValue(v,kCFNumberIntType,&r); CFRelease(k); CFRelease(ps); return r; }
static char tgkeys[128][5]; static int ntg=0;
int main(int argc,char**argv){
  int secs=argc>1?atoi(argv[1]):10; double iv=argc>2?atof(argv[2]):1.0;
  load_table(); int smc=smc_open();
  if(!smc){ int n=smc_count(); for(int i=0;i<n;i++){ char nm[5]; if(!smc_key_at(i,nm) && nm[0]=='T'&&nm[1]=='g' && ntg<128) strcpy(tgkeys[ntg++],nm);} }
  CFDictionaryRef a=IOReportCopyChannelsInGroup(CFSTR("GPU Stats"),CFSTR("GPU Performance States"),0,0,0);
  CFDictionaryRef b=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
  CFMutableDictionaryRef m=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,a); IOReportMergeChannels(m,b,NULL);
  CFMutableDictionaryRef sc=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,m,&sc,0,NULL);
  printf("# table entries=%d (MHz):",ntbl); for(int i=0;i<ntbl;i++) printf(" %.0f",tbl[i]); printf("\n# smc_open=%d Tg keys=%d\n",smc,ntg);
  printf("time\tdevUtil\trenUtil\tGPUPH_act%%\tavgMHz\ttopState\tGPU_W\tPSTR_W\tPDTR_W\tPMVC_W\tPHPC_W\tTg_avg\tTg_min\tTg_max\n");
  CFDictionaryRef prev=IOReportCreateSamples(sub,sc,NULL); double pt=now();
  for(int i=0;i<(int)(secs/iv);i++){
    usleep((useconds_t)(iv*1e6));
    CFDictionaryRef cur=IOReportCreateSamples(sub,sc,NULL); double t=now();
    CFDictionaryRef d=IOReportCreateSamplesDelta(prev,cur,NULL);
    CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
    double act=0,tot=0,fs=0,gj=0; double res[32]={0}; int ns=0;
    for(CFIndex j=0;j<CFArrayGetCount(arr);j++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,j); char g[64],n[64]; cs(IOReportChannelGetGroup(c),g,64); cs(IOReportChannelGetChannelName(c),n,64);
      if(!strcmp(g,"GPU Stats")&&!strcmp(n,"GPUPH")){ ns=IOReportStateGetCount(c); for(int k=0;k<ns&&k<32;k++){ double r=(double)IOReportStateGetResidency(c,k); res[k]=r; tot+=r; if(k>0){ act+=r; fs+=r*(k<ntbl?tbl[k]:tbl[ntbl-1]); } } }
      else if(!strcmp(n,"GPU Energy")) gj=IOReportSimpleGetIntegerValue(c,0)/1e9; }
    int top=0; for(int k=1;k<ns;k++) if(res[k]>res[top]) top=k;
    double tsum=0,tmin=1e9,tmax=-1e9; int tn=0; for(int k=0;k<ntg;k++){ double v=smc_val(tgkeys[k]); if(v>-900){ tsum+=v; tn++; if(v<tmin)tmin=v; if(v>tmax)tmax=v; } }
    time_t tt=time(NULL); char hb[16]; strftime(hb,16,"%H:%M:%S",localtime(&tt));
    printf("%s\t%d\t%d\t%.1f\t%.0f\tP%d\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\n",hb,perfstat("Device Utilization %"),perfstat("Renderer Utilization %"),
      tot>0?100*act/tot:0, act>0?fs/act:0, top, gj/(t-pt), smc_val("PSTR"), smc_val("PDTR"), smc_val("PMVC"), smc_val("PHPC"), tn?tsum/tn:-1, tmin, tmax);
    fflush(stdout); CFRelease(d); CFRelease(prev); prev=cur; pt=t;
  }
  return 0; }
