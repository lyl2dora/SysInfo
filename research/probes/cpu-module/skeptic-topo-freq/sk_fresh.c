// 复核探针 5：「实时 / 非实时」核对（只读；无负载；全程约 35 s）。
//  a) HOST_CPU_LOAD_INFO 在 1 Hz / 4 Hz / 20 Hz 下与上一次完全相同的次数（XNU 对第三方进程的 host_statistics 限流是全局的）；
//  b) host_processor_info(CPU_LOAD_INFO) 与 (CPU_STAT64) 在 20 Hz 下的陈旧次数；CPU_STAT64 的返回码与每秒计数；
//  c) IOReport CPM 簇通道：每 50 ms 采一次，看「所有状态驻留增量之和」是否随墙钟连续增长（是否实时积分、单位是多少）；
//  d) getloadavg 每 1 s 读一次 12 次，看多久变一次（BSD 负载均值由内核定时更新）。
#include "sk.h"
#include <mach/processor_info.h>
#include <unistd.h>
#include <math.h>

static void hostLoad(int hz, int n){ host_t H=mach_host_self(); host_cpu_load_info_data_t prev={0}, cur; int same=0, kr0=0;
  for(int i=0;i<n;i++){ mach_msg_type_number_t c=HOST_CPU_LOAD_INFO_COUNT; kern_return_t kr=host_statistics(H,HOST_CPU_LOAD_INFO,(host_info_t)&cur,&c); if(kr) kr0=kr;
    if(i && !memcmp(&cur,&prev,sizeof cur)) same++; prev=cur; usleep(1000000/hz); }
  printf("HOST_CPU_LOAD_INFO @%2d Hz: %d/%d identical to previous (kr=%d)\n", hz, same, n-1, kr0); fflush(stdout); }

int main(void){
  char model[64]={0}; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0); time_t now=time(NULL); char ts[32]; strftime(ts,32,"%F %T",localtime(&now));
  printf("model=%s start=%s\n", model, ts);
  hostLoad(1,8); sleep(1); hostLoad(4,16); sleep(1); hostLoad(20,40); sleep(1);
  // b)
  { host_t H=mach_host_self(); uint64_t prevSum=0; int same=0;
    for(int i=0;i<40;i++){ uint64_t t[SK_MAXCPU][4]; int n=sk_ticks(t); uint64_t s=0; for(int c=0;c<n;c++) for(int k=0;k<4;k++) s+=t[c][k]; if(i && s==prevSum) same++; prevSum=s; usleep(50000); }
    printf("host_processor_info(CPU_LOAD_INFO) @20 Hz: %d/39 identical\n", same);
    uint64_t pirq=0, pipi=0, ptim=0; int st=0; double t0=0, tprev=0; double rates[3]={0}; int nr=0;
    for(int i=0;i<40;i++){ natural_t n; processor_info_array_t info; mach_msg_type_number_t cnt; kern_return_t kr=host_processor_info(H,PROCESSOR_CPU_STAT64,&n,&info,&cnt);
      if(kr){ printf("PROCESSOR_CPU_STAT64 kr=%d\n", kr); break; }
      uint64_t irq=0, ipi=0, tim=0; for(unsigned c=0;c<n;c++){ processor_cpu_stat64_t p=(processor_cpu_stat64_t)(info+c*PROCESSOR_CPU_STAT64_COUNT); irq+=p->irq_ex_cnt; ipi+=p->ipi_cnt; tim+=p->timer_cnt; }
      vm_deallocate(mach_task_self(),(vm_address_t)info,cnt*sizeof(int)); double tn=sk_now_s();
      if(i){ if(irq==pirq) st++; } else t0=tn;
      if(i==39){ rates[0]=(irq-rates[0])/(tn-t0); rates[1]=(ipi-rates[1])/(tn-t0); rates[2]=(tim-rates[2])/(tn-t0); } if(i==0){ rates[0]=irq; rates[1]=ipi; rates[2]=tim; }
      pirq=irq; pipi=ipi; ptim=tim; tprev=tn; usleep(50000); }
    printf("PROCESSOR_CPU_STAT64 @20 Hz: %d/39 identical irq sums; over %.1f s: irq_ex %.0f/s ipi %.0f/s timer %.0f/s residual %.0f/s\n", st, tprev-t0, rates[0], rates[1], rates[2], rates[0]-rates[1]-rates[2]); fflush(stdout); }
  // c)
  { CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0); CFMutableDictionaryRef sb=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sb,0,NULL);
    CFDictionaryRef prev=IOReportCreateSamples(sub,sb,NULL); double tp=sk_now_s(); double ratio[20]; int zero=0; char nm0[32]="";
    for(int i=0;i<20;i++){ usleep(50000); CFDictionaryRef cur=IOReportCreateSamples(sub,sb,NULL); double tn=sk_now_s(); CFDictionaryRef d=IOReportCreateSamplesDelta(prev,cur,NULL); CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
      CFDictionaryRef c0=CFArrayGetValueAtIndex(arr,0); sk_cs(IOReportChannelGetChannelName(c0),nm0,32); double tot=0; int n=IOReportStateGetCount(c0); for(int k=0;k<n;k++) tot+=(double)IOReportStateGetResidency(c0,k);
      ratio[i]=tot/((tn-tp)*1e9); if(tot==0) zero++; CFRelease(d); CFRelease(prev); prev=cur; tp=tn; }
    double mn=1e18,mx=0; for(int i=0;i<20;i++){ if(ratio[i]<mn) mn=ratio[i]; if(ratio[i]>mx) mx=ratio[i]; }
    printf("IOReport %s @20 Hz: total residency delta / wall ns = %.4f..%.4f (x 41.667 = ticks of 24 MHz? %.3f..%.3f), zero-delta samples %d/20\n", nm0, mn, mx, mn*1e9/24e6, mx*1e9/24e6, zero); fflush(stdout); }
  // d)
  { double prev[3]={-1,-1,-1}; int changes=0; printf("getloadavg 1 Hz x12, change marks:"); for(int i=0;i<12;i++){ double l[3]; getloadavg(l,3); int ch= i && (l[0]!=prev[0]); changes+=ch; printf(" %s%.2f", ch?"*":"", l[0]); memcpy(prev,l,sizeof l); sleep(1); } printf("  -> %d changes in 11 s\n", changes); }
  return 0; }
