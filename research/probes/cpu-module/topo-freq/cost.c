// 探针：CPU 模块各数据源每次采样的开销（本线程 CPU 时间 + 墙钟），两台机器通用。
// 每项跑 R 轮 × N 次，报告每次调用的中位数（线程 CPU µs）与最小/最大轮，便于识别其他进程带来的噪声。
// IOReport 各订阅方式分别测：只含 1 条通道、只含实际频率簇通道、簇 + 逐核、整组 CPU Stats、中断统计、GPU Stats（对照）。
#include "topo_discover.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>

#define R 7
static double cpu_us(void){ return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)/1000.0; }
static double wall_us(void){ return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000.0; }
static int cmpd(const void* a, const void* b){ double x=*(double*)a, y=*(double*)b; return x<y?-1:x>y; }
typedef void (*fn_t)(void*);
static void bench(const char* name, fn_t f, void* ctx, int n){
  double c[R], w[R]; f(ctx); int onPL0=0, cnt=0;
  for(int r=0;r<R;r++){ double c0=cpu_us(), w0=wall_us(); for(int i=0;i<n;i++){ f(ctx); size_t cpu; if(pthread_cpu_number_np(&cpu)==0 && cpu<TD_MAXCPU){ cnt++; if(td_ncl && td_clusterPerfLevel(td_cpuCluster[cpu])==0) onPL0++; } } c[r]=(cpu_us()-c0)/n; w[r]=(wall_us()-w0)/n; usleep(20000); }
  qsort(c,R,sizeof(double),cmpd); qsort(w,R,sizeof(double),cmpd);
  printf("%-58s cpu median %8.1f us (min %8.1f max %8.1f) | wall median %8.1f us | on perflevel0 %3.0f%%\n", name, c[R/2], c[0], c[R-1], w[R/2], cnt? 100.0*onPL0/cnt:0); fflush(stdout); }

// ---- 公开 / Mach ----
static host_t H;
static void f_hpi(void* x){ natural_t n; processor_info_array_t info; mach_msg_type_number_t c; host_processor_info(H, PROCESSOR_CPU_LOAD_INFO, &n, &info, &c); vm_deallocate(mach_task_self(), (vm_address_t)info, c*sizeof(int)); }
static void f_hcpu(void* x){ host_cpu_load_info_data_t d; mach_msg_type_number_t c=HOST_CPU_LOAD_INFO_COUNT; host_statistics(H, HOST_CPU_LOAD_INFO, (host_info_t)&d, &c); }
static void f_loadavg(void* x){ double l[3]; getloadavg(l,3); }
static processor_set_name_t PS;
static void f_pset(void* x){ struct processor_set_load_info li; mach_msg_type_number_t c=PROCESSOR_SET_LOAD_INFO_COUNT; processor_set_statistics(PS, PROCESSOR_SET_LOAD_INFO, (processor_set_info_t)&li, &c); }
static void f_csw(void* x){ static int pids[16384]; int n=proc_listallpids(pids,sizeof pids); long long s=0; for(int i=0;i<n;i++){ struct proc_taskinfo ti; if(proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &ti, sizeof ti)==sizeof ti) s+=ti.pti_csw; } }
static void f_topo(void* x){ td_discover(); }
static void f_dt(void* x){ td_readPerfLevels(); td_readDT(); }
static void f_pm(void* x){ td_readPmgr(); }
static void f_irs(void* x){ td_readIOReportStructure(); }

// ---- IOReport ----
typedef struct { IOReportSubscriptionRef sub; CFMutableDictionaryRef subbed; CFDictionaryRef prev; int delta; } IOR;
static void f_ior(void* x){ IOR* r=x; CFDictionaryRef s=IOReportCreateSamples(r->sub,r->subbed,NULL);
  if(r->delta){ if(r->prev){ CFDictionaryRef d=IOReportCreateSamplesDelta(r->prev,s,NULL); CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
      // 解析：遍历每条通道的状态驻留（模拟真实采集器的解析开销）
      volatile int64_t sink=0; for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); int n=IOReportStateGetCount(ch); for(int k=0;k<n;k++) sink+=IOReportStateGetResidency(ch,k); }
      CFRelease(d); CFRelease(r->prev); } r->prev=s; }
  else CFRelease(s); }
// 从一组通道里只保留名字在 keep 列表中的通道
static CFMutableDictionaryRef filtered(CFMutableDictionaryRef all, const char** keep, int nk){
  CFArrayRef arr=CFDictionaryGetValue(all,CFSTR("IOReportChannels")); CFMutableArrayRef out=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char nm[64]; td_cs(IOReportChannelGetChannelName(ch),nm,64); for(int k=0;k<nk;k++) if(!strcmp(nm,keep[k])){ CFArrayAppendValue(out,ch); break; } }
  CFMutableDictionaryRef d=CFDictionaryCreateMutableCopy(NULL,0,all); CFDictionarySetValue(d,CFSTR("IOReportChannels"),out); CFRelease(out); return d; }
static int nchan(CFDictionaryRef d){ CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); return a? (int)CFArrayGetCount(a) : 0; }
static void benchIOR(const char* label, CFMutableDictionaryRef ch, int n){
  if(!ch){ printf("%-58s (group missing)\n", label); return; }
  IOR r={0}; r.sub=IOReportCreateSubscription(NULL,ch,&r.subbed,0,NULL); if(!r.sub){ printf("%-58s subscription failed\n", label); return; }
  char nm[160]; snprintf(nm,sizeof nm,"IOReport %s [%d ch] sample", label, nchan(ch)); bench(nm,f_ior,&r,n);
  r.delta=1; snprintf(nm,sizeof nm,"IOReport %s [%d ch] sample+delta+parse", label, nchan(ch)); bench(nm,f_ior,&r,n); }

int main(int argc, char** argv){
  int n = argc>1? atoi(argv[1]) : 20;
  // 第二个参数：采样线程的 QoS（ui / default / utility / bg），默认 default
  const char* q = argc>2? argv[2] : "default"; qos_class_t qc = !strcmp(q,"ui")? QOS_CLASS_USER_INTERACTIVE : !strcmp(q,"utility")? QOS_CLASS_UTILITY : !strcmp(q,"bg")? QOS_CLASS_BACKGROUND : QOS_CLASS_DEFAULT;
  pthread_set_qos_class_self_np(qc,0); td_discover();
  H=mach_host_self(); processor_set_default(H,&PS);
  char model[64]; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0); double l[3]; getloadavg(l,3);
  printf("model=%s loadavg=%.2f %.2f %.2f  (N=%d per round, %d rounds, sampler QoS=%s)\n", model, l[0], l[1], l[2], n, R, q);
  bench("host_processor_info(PROCESSOR_CPU_LOAD_INFO)", f_hpi, NULL, 200);
  bench("host_statistics(HOST_CPU_LOAD_INFO)", f_hcpu, NULL, 200);
  bench("getloadavg", f_loadavg, NULL, 200);
  bench("processor_set_statistics(LOAD_INFO) tasks/threads", f_pset, NULL, 200);
  bench("sum pti_csw over all pids (libproc sweep)", f_csw, NULL, 5);
  bench("topology discovery (DT + pmgr + IOReport structure)", f_topo, NULL, 5);
  bench("  part: sysctl perflevels + IODeviceTree cpus", f_dt, NULL, 20);
  bench("  part: pmgr properties (perf-domains + voltage-states)", f_pm, NULL, 5);
  bench("  part: IOReport CPU Stats structure (subscribe + 1 sample)", f_irs, NULL, 5);

  td_discover();
  CFMutableDictionaryRef cx=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0);
  CFMutableDictionaryRef core=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Core Performance States"),0,0,0);
  const char* keep[TD_MAXCL]; int nk=0; for(int k=0;k<td_ncl;k++) if(td_cl[k].cpmName[0]) keep[nk++]=td_cl[k].cpmName;
  benchIOR("1 complex channel", filtered(cx,keep,1), n);
  benchIOR("actual-freq complex channels only", filtered(cx,keep,nk), n);
  benchIOR("Complex Performance States", cx, n);
  benchIOR("Core Performance States", core, n);
  CFMutableDictionaryRef both=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0);
  IOReportMergeChannels(both, IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Core Performance States"),0,0,0), NULL);
  benchIOR("Complex + Core Performance States", both, n);
  benchIOR("whole CPU Stats group", IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),NULL,0,0,0), n);
  benchIOR("Interrupt Statistics (by index)", IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"),NULL,0,0,0), n);
  benchIOR("GPU Stats (reference)", IOReportCopyChannelsInGroup(CFSTR("GPU Stats"),NULL,0,0,0), n);
  // 合并：实际频率簇通道 + 中断统计（一个订阅）
  CFMutableDictionaryRef m=filtered(cx,keep,nk); IOReportMergeChannels(m, IOReportCopyChannelsInGroup(CFSTR("Interrupt Statistics (by index)"),NULL,0,0,0), NULL);
  benchIOR("merged: actual-freq complex + Interrupt Statistics", m, n);
  return 0;
}
