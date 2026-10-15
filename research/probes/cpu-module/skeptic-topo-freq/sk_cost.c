// 复核探针 3：开销（只读；单线程；全程约 35 s）。独立核对 topo-freq 的开销数字，并补测它没测的两点：
//  (1) 按真实节奏（每 1 s 采一次）而不是紧循环测每次采样的线程 CPU 时间——紧循环下核心频率已拉高、缓存热，
//      可能低估 1 Hz 常驻时的真实开销；
//  (2) 「系统侧额外开销」A/B：同一线程交替做 1.5 s 纯自旋（A）与 1.5 s IOReport 采样紧循环（B），
//      用全机每核 tick 求忙碌核数，B−A 再扣掉本线程 CPU 占比之差，看内核/其他进程是否替我们干了活
//      （线程 CPU 时间看不到这部分）。
// 用法：sk_cost [utility|default|bg]
#include "sk.h"
#include <mach/processor_info.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <unistd.h>
#include <math.h>

static int cmpd(const void* a, const void* b){ double x=*(double*)a, y=*(double*)b; return x<y?-1:x>y; }
static double med(double* v, int n){ double t[256]; memcpy(t,v,n*sizeof(double)); qsort(t,n,sizeof(double),cmpd); return n%2? t[n/2] : (t[n/2-1]+t[n/2])/2; }
static int ncpu; static int plOfCpu[SK_MAXCPU];

static CFMutableDictionaryRef grp(const char* g, const char* sg){ CFStringRef G=CFStringCreateWithCString(NULL,g,kCFStringEncodingUTF8); CFStringRef S= sg? CFStringCreateWithCString(NULL,sg,kCFStringEncodingUTF8):NULL; CFMutableDictionaryRef d=IOReportCopyChannelsInGroup(G,S,0,0,0); CFRelease(G); if(S) CFRelease(S); return d; }
static CFMutableDictionaryRef keepNames(CFMutableDictionaryRef all, int (*pred)(const char*)){ CFArrayRef arr=CFDictionaryGetValue(all,CFSTR("IOReportChannels")); CFMutableArrayRef out=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char nm[64]; sk_cs(IOReportChannelGetChannelName(ch),nm,64); if(pred(nm)) CFArrayAppendValue(out,ch); }
  CFMutableDictionaryRef d=CFDictionaryCreateMutableCopy(NULL,0,all); CFDictionarySetValue(d,CFSTR("IOReportChannels"),out); CFRelease(out); return d; }
// 「实际频率」簇通道：名字里含 "CPM" 且不含 "_"（M5 的 *_IDLE 排除）。仅用于开销测量，不是发现算法。
static int isCPM(const char* n){ return strstr(n,"CPM") && !strchr(n,'_'); }
static int firstOnly_seen; static int firstOnly(const char* n){ (void)n; return firstOnly_seen++==0; }
static int nch(CFDictionaryRef d){ CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); return a? (int)CFArrayGetCount(a):0; }

typedef struct { IOReportSubscriptionRef sub; CFMutableDictionaryRef sb; CFDictionaryRef prev; } Sub;
static Sub mk(CFMutableDictionaryRef ch){ Sub s={0}; s.sub=IOReportCreateSubscription(NULL,ch,&s.sb,0,NULL); return s; }
static void sample(Sub* s){ CFDictionaryRef x=IOReportCreateSamples(s->sub,s->sb,NULL); if(s->prev){ CFDictionaryRef d=IOReportCreateSamplesDelta(s->prev,x,NULL); CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
    volatile int64_t sink=0; for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); int n=IOReportStateGetCount(ch); for(int k=0;k<n;k++) sink+=IOReportStateGetResidency(ch,k); } CFRelease(d); CFRelease(s->prev); } s->prev=x; }

static void tight(const char* label, CFMutableDictionaryRef ch){
  if(!ch){ printf("%-52s missing\n", label); return; }
  Sub s=mk(ch); if(!s.sub){ printf("%-52s subscribe failed\n", label); return; } sample(&s); sample(&s);
  double c[5]; int onP0=0, cnt=0; for(int r=0;r<5;r++){ double t0=sk_thread_cpu_us(); for(int i=0;i<20;i++){ sample(&s); size_t cpu; if(!pthread_cpu_number_np(&cpu)){ cnt++; onP0+= plOfCpu[cpu]==0; } } c[r]=(sk_thread_cpu_us()-t0)/20; usleep(20000); }
  qsort(c,5,sizeof(double),cmpd); printf("%-52s [%4d ch] tight loop: cpu/call median %7.0f us (min %6.0f max %6.0f) | on perflevel0 %3.0f%%\n", label, nch(ch), c[2], c[0], c[4], cnt? 100.0*onP0/cnt:0); fflush(stdout); }

static double busyCores(uint64_t a[][4], uint64_t b[][4]){ double s=0; for(int c=0;c<ncpu;c++){ double u=(b[c][0]-a[c][0])+(b[c][1]-a[c][1])+(b[c][3]-a[c][3]), id=b[c][2]-a[c][2]; if(u+id>0) s+=u/(u+id); } return s; }

int main(int argc, char** argv){
  const char* q= argc>1? argv[1] : "utility"; qos_class_t qc= !strcmp(q,"default")? QOS_CLASS_DEFAULT : !strcmp(q,"bg")? QOS_CLASS_BACKGROUND : QOS_CLASS_UTILITY; pthread_set_qos_class_self_np(qc,0);
  char model[64]={0}; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0); double la[3]; getloadavg(la,3); time_t now=time(NULL); char ts[32]; strftime(ts,32,"%F %T",localtime(&now));
  SKDT d; sk_read_dt(&d); ncpu=d.n;
  // perflevel0 的核：用 hw.perflevel0.logicalcpu_max 与 DT 簇大小匹配（只用于报告采样线程落点）
  { int n0=(int)sk_sysint("hw.perflevel0.logicalcpu_max"); for(int i=0;i<ncpu;i++){ int same=0; for(int j=0;j<ncpu;j++) same+= !strcmp(d.compat[j],d.compat[i]) && !strcmp(d.type[j],d.type[i]); plOfCpu[d.lcid[i]]= same==n0? 0 : 1; } }
  printf("model=%s start=%s loadavg=%.2f %.2f %.2f sampler QoS=%s\n", model, ts, la[0],la[1],la[2], q);

  // 0) 便宜的公开调用
  { double v[200]; host_t H=mach_host_self();
    for(int i=0;i<200;i++){ double t0=sk_thread_cpu_us(); natural_t n; processor_info_array_t info; mach_msg_type_number_t cnt; host_processor_info(H,PROCESSOR_CPU_LOAD_INFO,&n,&info,&cnt); vm_deallocate(mach_task_self(),(vm_address_t)info,cnt*sizeof(int)); v[i]=sk_thread_cpu_us()-t0; }
    printf("host_processor_info(CPU_LOAD_INFO)   cpu/call median %.1f us\n", med(v,200));
    for(int i=0;i<200;i++){ double t0=sk_thread_cpu_us(); natural_t n; processor_info_array_t info; mach_msg_type_number_t cnt; host_processor_info(H,PROCESSOR_CPU_STAT64,&n,&info,&cnt); vm_deallocate(mach_task_self(),(vm_address_t)info,cnt*sizeof(int)); v[i]=sk_thread_cpu_us()-t0; }
    printf("host_processor_info(CPU_STAT64)      cpu/call median %.1f us\n", med(v,200)); }

  CFMutableDictionaryRef cx=grp("CPU Stats","CPU Complex Performance States");
  // 1) 建订阅
  { double c[3], w[3]; for(int r=0;r<3;r++){ double t0=sk_thread_cpu_us(), w0=sk_now_s(); CFMutableDictionaryRef ch=keepNames(cx,isCPM); Sub s=mk(ch); c[r]=sk_thread_cpu_us()-t0; w[r]=(sk_now_s()-w0)*1e6; (void)s; }
    printf("IOReportCreateSubscription (CPM subset, incl. copy/filter): cpu %0.f/%0.f/%0.f us, wall %0.f/%0.f/%0.f us\n", c[0],c[1],c[2], w[0],w[1],w[2]); fflush(stdout); }

  // 2) 紧循环
  tight("CPM cluster channels only", keepNames(cx,isCPM));
  firstOnly_seen=0; tight("first channel of Complex Perf States only", keepNames(cx,firstOnly));
  tight("whole CPU Stats group", grp("CPU Stats",NULL));
  tight("Energy Model (whole group)", grp("Energy Model",NULL));
  { CFMutableDictionaryRef m=keepNames(cx,isCPM); IOReportMergeChannels(m,grp("Energy Model",NULL),NULL); tight("merged CPM + Energy Model", m); }
  tight("Interrupt Statistics (by index)", grp("Interrupt Statistics (by index)",NULL));
  { CFMutableDictionaryRef m=keepNames(cx,isCPM); IOReportMergeChannels(m,grp("Interrupt Statistics (by index)",NULL),NULL); tight("merged CPM + Interrupt Statistics", m); }

  // 3) 真实节奏：每 1 s 一次，12 次
  { Sub s=mk(keepNames(cx,isCPM)); sample(&s); double c[12], w[12]; int pl0=0; printf("1 Hz cadence (CPM subset, sample+delta+parse), per call cpu us:");
    for(int i=0;i<12;i++){ sleep(1); double t0=sk_thread_cpu_us(), w0=sk_now_s(); sample(&s); c[i]=sk_thread_cpu_us()-t0; w[i]=(sk_now_s()-w0)*1e6; size_t cpu=0; pthread_cpu_number_np(&cpu); pl0+= plOfCpu[cpu]==0; printf(" %.0f", c[i]); }
    double mx=0; for(int i=0;i<12;i++) if(c[i]>mx) mx=c[i];
    printf("\n  -> median cpu %.0f us (max %.0f), median wall %.0f us, ended on perflevel0 %d/12  => %.2f%% of one core at 1 Hz\n", med(c,12), mx, med(w,12), pl0, med(c,12)/1e4); fflush(stdout); }

  // 4) 系统侧额外开销 A/B
  { Sub s=mk(keepNames(cx,isCPM)); sample(&s); double ext[4]; printf("A/B system-side extra (busy cores B - A - (ourCPU_B - ourCPU_A)):");
    for(int r=0;r<4;r++){ uint64_t a0[SK_MAXCPU][4], a1[SK_MAXCPU][4], b0[SK_MAXCPU][4], b1[SK_MAXCPU][4];
      sk_ticks(a0); double ca=sk_thread_cpu_us(), wa=sk_now_s(); volatile uint64_t x=0; while(sk_now_s()-wa<1.5) for(int k=0;k<10000;k++) x+=k; double fa=(sk_thread_cpu_us()-ca)/((sk_now_s()-wa)*1e6); sk_ticks(a1);
      sk_ticks(b0); double cb=sk_thread_cpu_us(), wb=sk_now_s(); int calls=0; while(sk_now_s()-wb<1.5){ sample(&s); calls++; } double fb=(sk_thread_cpu_us()-cb)/((sk_now_s()-wb)*1e6); sk_ticks(b1);
      double A=busyCores(a0,a1), B=busyCores(b0,b1); ext[r]=(B-A)-(fb-fa); printf(" [A %.2f B %.2f ourA %.2f ourB %.2f calls %d extra %+.2f]", A, B, fa, fb, calls, ext[r]); fflush(stdout); }
    printf("\n  -> median extra %+.2f cores while sampling back-to-back\n", med(ext,4)); }
  return 0; }
