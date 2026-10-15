// sk_cost.c — 独立复核采集开销（线程 CPU 与墙钟，均取中位数与 p90）。只读。
// 1) SMC：打开 + 全枚举 keyinfo；读 N 个键（缓存 keyinfo）每次采样；每键开销。
// 2) IOReport Energy Model：整组 / 只 CPU 类通道 / 只 GPU Energy 三种订阅的 CreateSamples+Delta 开销。
// 3) notify_get_state(thermalpressurelevel)。
// 用法：sk_cost <前缀或全名,逗号分隔> [重复次数=40] [采样间隔ms=250]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <notify.h>
#include <CoreFoundation/CoreFoundation.h>
#include "sk_smc.h"
#include "sk_ior.h"
static int cmpd(const void*a,const void*b){ double x=*(const double*)a,y=*(const double*)b; return x<y?-1:x>y; }
static void stat(const char*lab,double*v,int n){ qsort(v,n,sizeof(double),cmpd); printf("%s: median %.3f  p10 %.3f  p90 %.3f  (n=%d)\n",lab,v[n/2],v[n/10],v[n*9/10],n); }
static int is_cpu(const char*n){ const char*k[]={"CPU Energy","EACC_CPU","PACC0_CPU","PACC1_CPU","PCPU","MCPU0","MCPU1","ECPU",NULL}; for(int i=0;k[i];i++) if(!strcmp(n,k[i])) return 1; return 0; }
int main(int argc,char**argv){
  const char*sel=argc>1?argv[1]:"Tp0,Tm0,Tm1,Tm2,RP00,RP01,RP02,RP04"; int reps=argc>2?atoi(argv[2]):40; int ivms=argc>3?atoi(argv[3]):250;
  double c0=sk_tcpu_ms(), w0=sk_wall(); if(sk_open()) return 1; static SkKey all[4096]; int na=sk_enum(all,4096,NULL,0);
  printf("SMC 打开+全枚举 %d 键 keyinfo：线程 CPU %.1f ms，墙钟 %.1f ms\n",na,sk_tcpu_ms()-c0,(sk_wall()-w0)*1e3);
  static SkKey K[1024]; int nk=0; char buf[512];
  for(int i=0;i<na;i++){ strncpy(buf,sel,511); for(char*p=strtok(buf,",");p;p=strtok(NULL,",")) if(!strncmp(all[i].name,p,strlen(p))){ K[nk++]=all[i]; break; } }
  double *vc=malloc(sizeof(double)*reps), *vw=malloc(sizeof(double)*reps);
  for(int r=0;r<reps;r++){ usleep(ivms*1000); double a=sk_tcpu_ms(), b=sk_wall(); for(int i=0;i<nk;i++){ uint8_t x[32]; double v; if(!sk_raw(&K[i],x)) sk_val(&K[i],x,&v); } vc[r]=sk_tcpu_ms()-a; vw[r]=(sk_wall()-b)*1e3; }
  char lab[128]; snprintf(lab,128,"SMC 读 %d 键 线程CPU ms",nk); stat(lab,vc,reps); snprintf(lab,128,"SMC 读 %d 键 墙钟 ms",nk); stat(lab,vw,reps);
  for(int r=0;r<reps;r++){ double a=sk_tcpu_ms(), b=sk_wall(); uint8_t x[32]; sk_raw(&K[0],x); vc[r]=sk_tcpu_ms()-a; vw[r]=(sk_wall()-b)*1e3; }
  stat("SMC 读 1 键 线程CPU ms",vc,reps); stat("SMC 读 1 键 墙钟 ms",vw,reps);
  for(int mode=0;mode<3;mode++){
    CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
    if(mode){ CFArrayRef arr=CFDictionaryGetValue(ch,CFSTR("IOReportChannels")); CFMutableArrayRef keep=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
      for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char nm[64]; sk_cf(IOReportChannelGetChannelName(c),nm,64); if(mode==1? is_cpu(nm): !strcmp(nm,"GPU Energy")) CFArrayAppendValue(keep,c); }
      CFDictionarySetValue(ch,CFSTR("IOReportChannels"),keep); CFRelease(keep); }
    CFMutableDictionaryRef sd=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sd,0,NULL); CFDictionaryRef prev=IOReportCreateSamples(sub,sd,NULL); long nch=0;
    for(int r=0;r<reps;r++){ usleep(ivms*1000); double a=sk_tcpu_ms(), b=sk_wall(); CFDictionaryRef cur=IOReportCreateSamples(sub,sd,NULL); CFDictionaryRef d=IOReportCreateSamplesDelta(prev,cur,NULL);
      CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); nch=CFArrayGetCount(arr); int64_t s=0; for(CFIndex i=0;i<nch;i++) s+=IOReportSimpleGetIntegerValue(CFArrayGetValueAtIndex(arr,i),NULL); (void)s;
      CFRelease(d); CFRelease(prev); prev=cur; vc[r]=sk_tcpu_ms()-a; vw[r]=(sk_wall()-b)*1e3; }
    snprintf(lab,128,"IOReport EM %s (%ld 通道) 线程CPU ms",mode==0?"整组":mode==1?"CPU 子集":"仅 GPU Energy",nch); stat(lab,vc,reps);
    snprintf(lab,128,"IOReport EM %s 墙钟 ms",mode==0?"整组":mode==1?"CPU 子集":"仅 GPU Energy"); stat(lab,vw,reps); }
  int tok; notify_register_check("com.apple.system.thermalpressurelevel",&tok);
  for(int r=0;r<reps;r++){ double a=sk_tcpu_ms(); uint64_t st; for(int i=0;i<1000;i++) notify_get_state(tok,&st); vc[r]=(sk_tcpu_ms()-a)/1000*1e3; }
  stat("notify_get_state 线程CPU µs",vc,reps);
  return 0; }
