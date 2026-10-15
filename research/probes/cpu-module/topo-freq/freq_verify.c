// 探针：频率与拓扑映射的实测核对（两台机器通用；负载每阶段 3.5 s，总计 < 25 s）。
//
// 每个阶段起 N 个自旋线程（依赖加法链：每条 add 1 周期 → 加法数 / 线程 CPU 时间 = 实际 MHz，真值），
// 同一窗口里对比：
//   a) IOReport 簇通道「实际」（CPM 类）驻留 × DVFS 表 → 簇平均活跃频率
//   b) IOReport 簇通道「请求」（CPU 类）驻留 × DVFS 表
//   c) IOReport 逐核通道驻留 × DVFS 表，按簇平均（请求）
//   d) rusage_info_v6 ri_cycles / CPU 时间（本进程）
// 另外核对拓扑映射：线程用 pthread_cpu_number_np 记录所在 logical cpu，按发现的「cpu → 簇 → perflevel」
// 统计落在 perflevel0 的比例，与内核给的 ri_*_ptime / ri_*_time（perflevel0 上的时间占比）对照。
// 负载阶段按发现的拓扑生成（不写死核数）。只读；只结束自己的线程。
#include "topo_discover.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include <math.h>

static atomic_int stop_flag; static qos_class_t gq;
static double tMHz[TD_MAXCPU]; static uint32_t tHist[TD_MAXCPU][TD_MAXCPU];
static void* worker(void* arg){ int id=(int)(long)arg; pthread_set_qos_class_self_np(gq,0);
  uint64_t x=0, iters=0; memset(tHist[id],0,sizeof tHist[id]);
  uint64_t c0=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
  while(!atomic_load_explicit(&stop_flag, memory_order_relaxed)){
    for(int k=0;k<200;k++){ __asm__ volatile(".rept 100\n add %0, %0, #1\n .endr\n" : "+r"(x)); }
    iters+=200; size_t cpu=0; if(pthread_cpu_number_np(&cpu)==0 && cpu<TD_MAXCPU) tHist[id][cpu]++; }
  uint64_t c1=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
  tMHz[id]=(double)iters*100.0/((c1-c0)/1e9)/1e6; (void)x; return NULL; }

typedef struct { uint64_t cyc, t, pt; } RU;
static RU ru(void){ struct rusage_info_v6 r; RU o={0}; if(proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t*)&r)==0){ o.cyc=r.ri_cycles; o.t=r.ri_user_time+r.ri_system_time; o.pt=r.ri_user_ptime+r.ri_system_ptime; } return o; }

static int ticks(uint32_t out[][4]){ natural_t n; processor_info_array_t info; mach_msg_type_number_t cnt;
  if(host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt)) return 0;
  for(unsigned i=0;i<n && i<TD_MAXCPU;i++) for(int s=0;s<4;s++) out[i][s]=(uint32_t)info[i*CPU_STATE_MAX+s];
  vm_deallocate(mach_task_self(), (vm_address_t)info, cnt*sizeof(int)); return (int)n; }

// 从一条状态通道（delta）求活跃比例与平均活跃 MHz
static void chanFreq(CFDictionaryRef ch, const double* tbl, int ntbl, double* act, double* mhz){
  int n=IOReportStateGetCount(ch); double tot=0, a=0, f=0;
  for(int k=0;k<n;k++){ char st[32]; td_cs(IOReportStateGetNameForIndex(ch,k),st,32); double r=(double)IOReportStateGetResidency(ch,k); tot+=r;
    if(td_isV(st)){ int vi=atoi(st+1); if(vi>=0 && vi<ntbl){ a+=r; f+=r*tbl[vi]; } } }
  *act= tot? a/tot : 0; *mhz= a? f/a : 0; }

static double median(double* v, int n){ double t[TD_MAXCPU]; memcpy(t,v,n*sizeof(double)); for(int i=0;i<n;i++) for(int j=i+1;j<n;j++) if(t[j]<t[i]){ double z=t[i]; t[i]=t[j]; t[j]=z; } return n? (n%2? t[n/2] : (t[n/2-1]+t[n/2])/2) : 0; }

int main(int argc, char** argv){
  td_discover(); td_print(stdout);
  double win = argc>1? atof(argv[1]) : 3.0;
  CFMutableDictionaryRef a=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Core Performance States"),0,0,0);
  IOReportMergeChannels(a, IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0), NULL);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,a,&subbed,0,NULL);
  if(!sub){ printf("IOReport subscription failed\n"); return 1; }

  // 阶段按拓扑生成：1 个 UI 线程；perflevel0 核数个 UI 线程；全部核数 UTILITY；最低档一个簇大小的 BACKGROUND
  int n0 = td_npl? td_pl[0].logical : 1, nlast = td_npl? td_pl[td_npl-1].cpusperl2 : 1;
  struct { char name[64]; qos_class_t q; int n; } ph[5]; int nph=0;
  snprintf(ph[nph].name,64,"idle (no load)"); ph[nph].q=QOS_CLASS_DEFAULT; ph[nph].n=0; nph++;
  snprintf(ph[nph].name,64,"1x USER_INTERACTIVE"); ph[nph].q=QOS_CLASS_USER_INTERACTIVE; ph[nph].n=1; nph++;
  snprintf(ph[nph].name,64,"%dx USER_INTERACTIVE (=perflevel0 cores)", n0); ph[nph].q=QOS_CLASS_USER_INTERACTIVE; ph[nph].n=n0; nph++;
  snprintf(ph[nph].name,64,"%dx UTILITY (=all cores)", td_ncpu); ph[nph].q=QOS_CLASS_UTILITY; ph[nph].n=td_ncpu; nph++;
  snprintf(ph[nph].name,64,"%dx BACKGROUND (=cpusperl2 of last level)", nlast); ph[nph].q=QOS_CLASS_BACKGROUND; ph[nph].n=nlast; nph++;

  for(int p=0;p<nph;p++){
    gq=ph[p].q; atomic_store(&stop_flag,0); pthread_t th[TD_MAXCPU]; for(int i=0;i<ph[p].n;i++) pthread_create(&th[i],NULL,worker,(void*)(long)i);
    usleep(500000);
    uint32_t t0[TD_MAXCPU][4], t1[TD_MAXCPU][4]; ticks(t0); RU r0=ru(); CFDictionaryRef s1=IOReportCreateSamples(sub,subbed,NULL);
    usleep((useconds_t)(win*1e6));
    CFDictionaryRef s2=IOReportCreateSamples(sub,subbed,NULL); RU r1=ru(); ticks(t1);
    atomic_store(&stop_flag,1); for(int i=0;i<ph[p].n;i++) pthread_join(th[i],NULL);
    printf("\n== %s (window %.1f s) ==\n", ph[p].name, win);
    // 线程所在位置
    uint64_t onCl[TD_MAXCL]={0}, onPL[TD_MAXPL]={0}, tot=0;
    for(int i=0;i<ph[p].n;i++) for(int c=0;c<td_ncpu;c++){ uint32_t h=tHist[i][c]; tot+=h; onCl[td_cpuCluster[c]]+=h; int pl=td_clusterPerfLevel(td_cpuCluster[c]); if(pl>=0) onPL[pl]+=h; }
    if(ph[p].n){ printf(" truth add-chain MHz: median %.0f  (per thread:", median(tMHz,ph[p].n)); for(int i=0;i<ph[p].n && i<24;i++) printf(" %.0f", tMHz[i]); printf(")\n");
      printf(" where threads ran (pthread_cpu_number_np samples):"); for(int k=0;k<td_ncl;k++) printf(" cluster%u=%.1f%%", td_cl[k].id, tot? 100.0*onCl[k]/tot:0);
      printf(" | perflevel0 share by our map=%.1f%%", tot? 100.0*onPL[0]/tot:0);
      printf(" | kernel ri_*_ptime share=%.1f%%\n", r1.t>r0.t? 100.0*(r1.pt-r0.pt)/(r1.t-r0.t):0);
      printf(" rusage ri_cycles / cpu-time (whole process): %.0f MHz\n", r1.t>r0.t? (double)(r1.cyc-r0.cyc)/((r1.t-r0.t)*125.0/3/1e9)/1e6 : 0); }
    // 各簇 busy%（host_processor_info）
    printf(" cluster busy (host_processor_info):");
    for(int k=0;k<td_ncl;k++){ double b=0, t=0; for(int j=0;j<td_cl[k].ncores;j++){ int c=td_cl[k].cpus[j]; double u=(t1[c][0]-t0[c][0])+(t1[c][1]-t0[c][1])+(t1[c][3]-t0[c][3]); double id=t1[c][2]-t0[c][2]; b+=u; t+=u+id; } printf(" cluster%u=%.0f%%", td_cl[k].id, t?100*b/t:0); } printf("\n");
    // IOReport 频率
    CFDictionaryRef d=IOReportCreateSamplesDelta(s1,s2,NULL); CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
    double sumS=0, sumSoverA=0, sumSoverR=0; // 按线程所在簇做时间加权：样本数 ∝ 时间 × 频率
    for(int k=0;k<td_ncl;k++){ TDCluster* c=&td_cl[k]; double actA=0,mA=0,actR=0,mR=0, coreSumF=0, coreSumA=0; int coreIdx=0;
      for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char sg[96], nm[32]; td_cs(IOReportChannelGetSubGroup(ch),sg,96); td_cs(IOReportChannelGetChannelName(ch),nm,32);
        if(!strcmp(sg,"CPU Complex Performance States")){ if(c->cpmName[0] && !strcmp(nm,c->cpmName)) chanFreq(ch,c->tbl,c->ntbl,&actA,&mA); if(c->cpuName[0] && !strcmp(nm,c->cpuName)) chanFreq(ch,c->tbl,c->ntbl,&actR,&mR); }
        else if(!strcmp(sg,"CPU Core Performance States")){ for(int j=0;j<c->ncores;j++) if(!strcmp(nm,c->coreNames[j])){ double aa,mm; chanFreq(ch,c->tbl,c->ntbl,&aa,&mm); coreSumF+=aa*mm; coreSumA+=aa; } } }
      printf(" cluster%u [perflevel%d]: actual(%s) %3.0f%% active @ %4.0f MHz | requested cluster(%s) %3.0f%% @ %4.0f | requested per-core avg %3.0f%% @ %4.0f\n",
        c->id, td_clusterPerfLevel(k), c->cpmName[0]?c->cpmName:"-", 100*actA, mA, c->cpuName[0]?c->cpuName:"-", 100*actR, mR, 100*coreSumA/c->ncores, coreSumA? coreSumF/coreSumA:0);
      if(ph[p].n && onCl[k] && mA>0 && mR>0){ sumS+=onCl[k]; sumSoverA+=onCl[k]/mA; sumSoverR+=onCl[k]/mR; }
      // 若线程 ≥90% 落在本簇，给出与真值的误差
      if(ph[p].n && tot && onCl[k]*10>=tot*9){ double tr=median(tMHz,ph[p].n); printf("   -> threads on this cluster: actual err %+.1f%%, requested-cluster err %+.1f%%, requested-core err %+.1f%%\n", mA? 100*(mA-tr)/tr:0, mR? 100*(mR-tr)/tr:0, coreSumA? 100*(coreSumF/coreSumA-tr)/tr:0); }
    }
    if(ph[p].n && sumSoverA>0 && r1.t>r0.t){ double cyc=(double)(r1.cyc-r0.cyc)/((r1.t-r0.t)*125.0/3/1e9)/1e6, eA=sumS/sumSoverA, eR=sumS/sumSoverR;
      printf(" time-weighted over clusters the threads ran on: actual %.0f MHz (%+.2f%% vs ri_cycles %.0f) | requested %.0f MHz (%+.2f%%)\n", eA, 100*(eA-cyc)/cyc, cyc, eR, 100*(eR-cyc)/cyc); }
    // 逐核对照：host_processor_info 忙碌% vs 逐核 IOReport 通道非 IDLE/DOWN 驻留%（验证「逐核通道顺序 = logical cpu」）
    printf(" per-core busy%%(ticks)/active%%(IOReport core channel k):");
    double sumAbs=0; int ncmp=0;
    for(int cpu=0; cpu<td_ncpu && cpu<td_ncoreChan; cpu++){ double u=(t1[cpu][0]-t0[cpu][0])+(t1[cpu][1]-t0[cpu][1])+(t1[cpu][3]-t0[cpu][3]); double id=t1[cpu][2]-t0[cpu][2]; double busy= (u+id)? 100*u/(u+id) : 0;
      double act=0; for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char sg[96], nm[32]; td_cs(IOReportChannelGetSubGroup(ch),sg,96); td_cs(IOReportChannelGetChannelName(ch),nm,32);
        if(!strcmp(sg,"CPU Core Performance States") && !strcmp(nm,td_coreChan[cpu])){ int n=IOReportStateGetCount(ch); double tot=0,a=0; for(int k=0;k<n;k++){ char st[32]; td_cs(IOReportStateGetNameForIndex(ch,k),st,32); double r=(double)IOReportStateGetResidency(ch,k); tot+=r; if(td_isV(st)) a+=r; } act= tot? 100*a/tot:0; } }
      printf(" %d:%.0f/%.0f", cpu, busy, act); sumAbs+=fabs(busy-act); ncmp++; }
    printf("  | mean |diff| %.1f pp\n", ncmp? sumAbs/ncmp:0);
    CFRelease(d); CFRelease(s1); CFRelease(s2);
    sleep(2);
  }
  return 0;
}
