// 探针：同一驱动（PMGR）的多个组合并成一个订阅时，每次采样开销是否仍是「一份」固定成本；
// 以及不同驱动（中断统计、GPU）合并时是否相加。线程 CPU 时间，7 轮 × N 次取中位数（只读）。
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include "ioreport.h"
#define R 7
static int cmpd(const void* a, const void* b){ double x=*(double*)a, y=*(double*)b; return x<y?-1:x>y; }
static CFMutableDictionaryRef grp(const char* g, const char* sg){ CFStringRef G=CFStringCreateWithCString(NULL,g,kCFStringEncodingUTF8), S=sg? CFStringCreateWithCString(NULL,sg,kCFStringEncodingUTF8):NULL; CFMutableDictionaryRef d=IOReportCopyChannelsInGroup(G,S,0,0,0); return d; }
static void bench(const char* label, CFMutableDictionaryRef ch, int n){
  if(!ch){ printf("%-60s missing\n", label); return; }
  CFMutableDictionaryRef sb=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sb,0,NULL); if(!sub){ printf("%-60s sub failed\n", label); return; }
  double c[R]; CFRelease(IOReportCreateSamples(sub,sb,NULL));
  for(int r=0;r<R;r++){ double c0=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); for(int i=0;i<n;i++) CFRelease(IOReportCreateSamples(sub,sb,NULL)); c[r]=(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-c0)/1000.0/n; usleep(20000); }
  qsort(c,R,sizeof(double),cmpd); CFArrayRef a=CFDictionaryGetValue(ch,CFSTR("IOReportChannels"));
  printf("%-60s [%4ld ch] cpu median %7.0f us (min %7.0f max %7.0f)\n", label, a? CFArrayGetCount(a):0, c[R/2], c[0], c[R-1]); fflush(stdout); }
int main(int argc, char** argv){ int n=argc>1? atoi(argv[1]):15;
  bench("CPU Stats / Complex Performance States", grp("CPU Stats","CPU Complex Performance States"), n);
  bench("Energy Model (whole)", grp("Energy Model",NULL), n);
  bench("SoC Stats / Cluster Power States", grp("SoC Stats","Cluster Power States"), n);
  { CFMutableDictionaryRef m=grp("CPU Stats","CPU Complex Performance States"); IOReportMergeChannels(m,grp("Energy Model",NULL),NULL); IOReportMergeChannels(m,grp("SoC Stats","Cluster Power States"),NULL); bench("merged PMGR: Complex Perf + Energy Model + Cluster Power", m, n); }
  bench("Interrupt Statistics (by index)", grp("Interrupt Statistics (by index)",NULL), n);
  bench("GPU Stats", grp("GPU Stats",NULL), n);
  { CFMutableDictionaryRef m=grp("CPU Stats","CPU Complex Performance States"); IOReportMergeChannels(m,grp("GPU Stats",NULL),NULL); bench("merged: Complex Perf (PMGR) + GPU Stats (AGX)", m, n); }
  return 0; }
