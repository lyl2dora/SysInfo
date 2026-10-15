// cost_bench.c — 每项采集的线程 CPU 开销（中位数）。只读。
// 1) SMC：打开 + 全枚举 keyinfo（启动一次）；按前缀集合读取一组键（缓存 keyinfo，每键 1 次 IOConnectCall）的每次采样开销；
// 2) IOReport Energy Model：整组订阅、仅 CPU 相关通道子集、仅 AGX「GPU Energy」通道 三种订阅的 CreateSamples+SamplesDelta 开销；
// 3) notify_get_state(thermalpressurelevel) 开销。
// 用法：cost_bench "<温度键前缀,逗号分隔>" "<功耗键全名,逗号分隔>" [采样次数=20]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <notify.h>
#include "smc_ro.h"
#include "ioreport.h"
static int cmpd(const void*a,const void*b){ double x=*(const double*)a,y=*(const double*)b; return x<y?-1:x>y; }
static double median(double*v,int n){ qsort(v,n,sizeof(double),cmpd); return n%2? v[n/2] : (v[n/2-1]+v[n/2])/2; }
static int is_cpu_channel(const char*n){
  static const char* keep[]={"CPU Energy","EACC_CPU","PACC0_CPU","PACC1_CPU","PCPU","MCPU0","MCPU1","ECPU",NULL};
  for(int i=0;keep[i];i++) if(!strcmp(n,keep[i])) return 1; return 0; }
int main(int argc,char**argv){
  if(argc<3){ fprintf(stderr,"usage\n"); return 2; } int ns=argc>3?atoi(argv[3]):20;
  double c0=thread_cpu_ms(); if(smc_open()) return 1; int n=smc_count();
  static SMCKeyMeta all[4096]; int na=0; for(int i=0;i<n&&na<4096;i++){ uint32_t k; if(smc_key_at(i,&k)) continue; if(!smc_keyinfo(k,&all[na])) na++; }
  double c1=thread_cpu_ms(); printf("SMC open+enumerate %d keys (keyinfo): %.1f ms CPU\n", na, c1-c0);
  // 温度键集合（按前缀，类型 flt）
  static SMCKeyMeta sel[1024]; int nsel=0; char pref[256]; strncpy(pref,argv[1],255);
  for(int i=0;i<na;i++){ char k[5],t[5]; s4(all[i].key,k); s4(all[i].type,t); if(strcmp(t,"flt ")) continue;
    char tmp[256]; strcpy(tmp,pref); for(char*p=strtok(tmp,",");p;p=strtok(NULL,",")) if(!strncmp(k,p,strlen(p))){ sel[nsel++]=all[i]; break; } }
  // 功耗键
  char pw[256]; strncpy(pw,argv[2],255); int npw=0; for(char*p=strtok(pw,",");p;p=strtok(NULL,",")){ SMCKeyMeta m; if(strlen(p)==4 && !smc_keyinfo(k4(p),&m)){ sel[nsel++]=m; npw++; } }
  double v[1000], vt[1000];
  for(int s=0;s<ns;s++){ double a=thread_cpu_ms(); for(int i=0;i<nsel;i++){ uint8_t b[32]; double x; if(!smc_read_raw(&sel[i],b)) smc_decode(&sel[i],b,&x); } v[s]=thread_cpu_ms()-a; usleep(200000); }
  printf("SMC read %d keys (%d temp by prefix '%s' + %d power): median %.3f ms CPU/sample (%.4f ms/key)\n", nsel, nsel-npw, argv[1], npw, median(v,ns), median(v,ns)/nsel);
  // 只读 1 个键的开销
  for(int s=0;s<ns;s++){ double a=thread_cpu_ms(); uint8_t b[32]; smc_read_raw(&sel[0],b); vt[s]=thread_cpu_ms()-a; }
  printf("SMC read 1 key: median %.4f ms CPU\n", median(vt,ns));
  // IOReport 整组
  for(int mode=0;mode<3;mode++){
    CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
    if(mode>=1){ CFArrayRef arr=CFDictionaryGetValue(ch,CFSTR("IOReportChannels")); CFMutableArrayRef keep=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
      for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char nm[64]; cfstr(IOReportChannelGetChannelName(c),nm,64); if(mode==1? is_cpu_channel(nm) : !strcmp(nm,"GPU Energy")) CFArrayAppendValue(keep,c); }
      CFDictionarySetValue(ch,CFSTR("IOReportChannels"),keep); CFRelease(keep); }
    CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
    CFDictionaryRef prev=IOReportCreateSamples(sub,subbed,NULL); long nch=0;
    for(int s=0;s<ns;s++){ usleep(200000); double a=thread_cpu_ms(); CFDictionaryRef cur=IOReportCreateSamples(sub,subbed,NULL); CFDictionaryRef d=IOReportCreateSamplesDelta(prev,cur,NULL);
      CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); nch=CFArrayGetCount(arr); int64_t sum=0; for(CFIndex i=0;i<nch;i++) sum+=IOReportSimpleGetIntegerValue(CFArrayGetValueAtIndex(arr,i),NULL);
      CFRelease(d); CFRelease(prev); prev=cur; v[s]=thread_cpu_ms()-a; (void)sum; }
    printf("IOReport Energy Model %s (%ld ch): median %.3f ms CPU/sample\n", mode==1? "CPU 子集": mode==2? "仅 AGX GPU Energy":"整组", nch, median(v,ns));
  }
  int tok; notify_register_check("com.apple.system.thermalpressurelevel",&tok);
  for(int s=0;s<ns;s++){ double a=thread_cpu_ms(); uint64_t st; for(int r=0;r<100;r++) notify_get_state(tok,&st); v[s]=(thread_cpu_ms()-a)/100; }
  printf("notify_get_state: median %.4f ms CPU\n", median(v,ns));
  return 0; }
