// 探针：公开 SDK 的 host_processor_info(PROCESSOR_CPU_STAT64)（mach/arm/processor_info.h）能否免特权读到每核
// IRQ / IPI / 定时器 / PMI 计数，作为「中断率」的廉价来源；与 IOReport "Interrupt Statistics (by index)" 的
// First Level Interrupt Handler Count 合计在同一 1 s 窗口里对照，并测每次调用开销（只读）。
#include <mach/mach.h>
#include <mach/arm/processor_info.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include "ioreport.h"
#define MAXC 256
static host_t H;
static int rd(processor_cpu_stat64_data_t* out, kern_return_t* krp){ natural_t n; processor_info_array_t info; mach_msg_type_number_t c;
  kern_return_t kr=host_processor_info(H, PROCESSOR_CPU_STAT64, &n, &info, &c); if(krp) *krp=kr; if(kr) return -1;
  if(c != n*PROCESSOR_CPU_STAT64_COUNT){ printf("unexpected count %u for %u cpus\n", c, n); }
  memcpy(out, info, n*sizeof(processor_cpu_stat64_data_t)); vm_deallocate(mach_task_self(), (vm_address_t)info, c*sizeof(int)); return (int)n; }
static long long irqIOReport(CFDictionaryRef d){ CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); long long t=0;
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef x=CFArrayGetValueAtIndex(arr,i); char nm[128]; CFStringGetCString(IOReportChannelGetChannelName(x),nm,128,kCFStringEncodingUTF8);
    if(strstr(nm,"First Level Interrupt Handler Count")) t+=IOReportSimpleGetIntegerValue(x,NULL); } return t; }
int main(void){
  H=mach_host_self(); processor_cpu_stat64_data_t a[MAXC], b[MAXC]; kern_return_t kr;
  int n=rd(a,&kr); printf("host_processor_info(PROCESSOR_CPU_STAT64): kr=%d (%s) cpus=%d\n", kr, mach_error_string(kr), n); if(n<0) return 1;
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"),NULL,0,0,0); CFMutableDictionaryRef sb=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sb,0,NULL);
  for(int rep=0; rep<3; rep++){
    rd(a,NULL); CFDictionaryRef s1=IOReportCreateSamples(sub,sb,NULL); uint64_t t0=clock_gettime_nsec_np(CLOCK_UPTIME_RAW); sleep(1);
    rd(b,NULL); CFDictionaryRef s2=IOReportCreateSamples(sub,sb,NULL); double el=(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)-t0)/1e9;
    unsigned long long irq=0, ipi=0, tmr=0, pmi=0; for(int i=0;i<n;i++){ irq+=b[i].irq_ex_cnt-a[i].irq_ex_cnt; ipi+=b[i].ipi_cnt-a[i].ipi_cnt; tmr+=b[i].timer_cnt-a[i].timer_cnt; pmi+=b[i].pmi_cnt-a[i].pmi_cnt; }
    CFDictionaryRef d=IOReportCreateSamplesDelta(s1,s2,NULL);
    printf("window %.3f s: CPU_STAT64 sum irq_ex=%llu/s ipi=%llu/s timer=%llu/s pmi=%llu/s | IOReport first-level interrupts=%lld/s\n", el, (unsigned long long)(irq/el), (unsigned long long)(ipi/el), (unsigned long long)(tmr/el), (unsigned long long)(pmi/el), (long long)(irqIOReport(d)/el));
    if(rep==0){ printf(" per-cpu irq_ex/ipi/timer in window:"); for(int i=0;i<n;i++) printf(" %d:%llu/%llu/%llu", i, b[i].irq_ex_cnt-a[i].irq_ex_cnt, b[i].ipi_cnt-a[i].ipi_cnt, b[i].timer_cnt-a[i].timer_cnt); printf("\n"); }
    CFRelease(d); CFRelease(s1); CFRelease(s2); }
  double c0=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); for(int i=0;i<2000;i++) rd(a,NULL); printf("cost: %.2f us thread CPU per call\n", (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-c0)/2000/1000);
  return 0; }
