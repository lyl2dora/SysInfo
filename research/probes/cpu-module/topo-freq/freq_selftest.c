// 探针：频率数据源的「主动自检」可行性——在采样线程自己的 QoS 下自旋 T ms，
// 用本进程 rusage ri_cycles / CPU 时间（硬件周期计数）对照同一窗口里该线程所在簇的 CPM×DVFS 表平均频率。
// 线程可能迁移：按 pthread_cpu_number_np 采样计数把各簇的实际频率做时间加权（样本 ∝ 时间×频率）。
// 每种 QoS × 窗口长度各做 5 次，输出偏差分布（只读；单线程，每次 ≤ 200 ms）。
#include "topo_discover.h"
#include <libproc.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
static IOReportSubscriptionRef sub; static CFMutableDictionaryRef subbed;
static double clusterMHz(CFDictionaryRef d, int k){ CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); TDCluster* c=&td_cl[k];
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char nm[32]; td_cs(IOReportChannelGetChannelName(ch),nm,32); if(strcmp(nm,c->cpmName[0]?c->cpmName:c->cpuName)) continue;
    int n=IOReportStateGetCount(ch); double a=0,f=0; for(int s=0;s<n;s++){ char st[32]; td_cs(IOReportStateGetNameForIndex(ch,s),st,32); if(!td_isV(st)) continue; int vi=atoi(st+1); if(vi<c->ntbl){ double r=(double)IOReportStateGetResidency(ch,s); a+=r; f+=r*c->tbl[vi]; } } return a? f/a : 0; } return 0; }
static double one(qos_class_t q, int ms){
  pthread_set_qos_class_self_np(q,0); usleep(2000);
  struct rusage_info_v6 r0, r1; uint32_t hist[TD_MAXCPU]={0}; volatile uint64_t x=0;
  CFDictionaryRef s1=IOReportCreateSamples(sub,subbed,NULL); proc_pid_rusage(getpid(),RUSAGE_INFO_V6,(rusage_info_t*)&r0);
  uint64_t end=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)+ms*1000000ull;
  while(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)<end){ for(int k=0;k<2000;k++) x+=k; size_t cpu; if(!pthread_cpu_number_np(&cpu) && cpu<TD_MAXCPU) hist[cpu]++; }
  proc_pid_rusage(getpid(),RUSAGE_INFO_V6,(rusage_info_t*)&r1); CFDictionaryRef s2=IOReportCreateSamples(sub,subbed,NULL);
  CFDictionaryRef d=IOReportCreateSamplesDelta(s1,s2,NULL);
  double cyc=(double)(r1.ri_cycles-r0.ri_cycles)/(((r1.ri_user_time+r1.ri_system_time)-(r0.ri_user_time+r0.ri_system_time))*125.0/3/1e9)/1e6;
  double S=0, SoverF=0; for(int c=0;c<td_ncpu;c++) if(hist[c]){ double f=clusterMHz(d,td_cpuCluster[c]); if(f>0){ S+=hist[c]; SoverF+=hist[c]/f; } }
  CFRelease(d); CFRelease(s1); CFRelease(s2); double est= SoverF? S/SoverF : 0; return est&&cyc? 100*(est-cyc)/cyc : NAN; }
int main(void){
  td_discover();
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0); sub=IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  struct { const char* n; qos_class_t q; } qs[]={{"utility",QOS_CLASS_UTILITY},{"default",QOS_CLASS_DEFAULT},{"background",QOS_CLASS_BACKGROUND}};
  int wins[]={20,50,100};
  for(int i=0;i<3;i++) for(int w=0;w<3;w++){ printf("QoS %-10s spin %3d ms: CPM-vs-ri_cycles err %%:", qs[i].n, wins[w]); double mx=0; for(int r=0;r<5;r++){ double e=one(qs[i].q,wins[w]); printf(" %+.2f", e); if(fabs(e)>mx) mx=fabs(e); } printf("  (max |err| %.2f%%)\n", mx); }
  return 0; }
