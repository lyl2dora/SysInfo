// 复核探针 4：按真实节奏测 PMGR 类 IOReport 采样开销 + 建订阅开销拆分（只读；单线程；全程约 45 s，几乎都在 sleep）。
//  a) 建订阅拆成三段计时：IOReportCopyChannelsInGroup（枚举通道）、IOReportCreateSubscription、首次 IOReportCreateSamples；
//  b) 在 utility / default / background 三种 QoS 下，每 1 s 醒来一次，连续做两次采样（第 1 次 = 真实常驻场景，
//     第 2 次 = 紧接着再采，核心已被第 1 次拉起），分别记录线程 CPU 时间与醒来时所在 perflevel；
//  c) utility 下每 5 s 一次，3 次。
// 用法：sk_cadence [hi]（hi = 只测 user-initiated / user-interactive 两种 QoS 的 1 Hz 节奏）
#include "sk.h"
#include <pthread.h>
#include <pthread/qos.h>
#include <unistd.h>

static int cmpd(const void* a, const void* b){ double x=*(double*)a, y=*(double*)b; return x<y?-1:x>y; }
static double med(double* v, int n){ double t[64]; memcpy(t,v,n*sizeof(double)); qsort(t,n,sizeof(double),cmpd); return n%2? t[n/2] : (t[n/2-1]+t[n/2])/2; }
static int plOfCpu[SK_MAXCPU];
static IOReportSubscriptionRef sub; static CFMutableDictionaryRef sb; static CFDictionaryRef prev;
static void sample(void){ CFDictionaryRef x=IOReportCreateSamples(sub,sb,NULL); if(prev){ CFDictionaryRef d=IOReportCreateSamplesDelta(prev,x,NULL); CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
    volatile int64_t s=0; for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); int n=IOReportStateGetCount(ch); for(int k=0;k<n;k++) s+=IOReportStateGetResidency(ch,k); } CFRelease(d); CFRelease(prev); } prev=x; }
static int curPL(void){ size_t c=0; pthread_cpu_number_np(&c); return plOfCpu[c]; }

static void run(const char* qn, qos_class_t q, int period, int n){
  pthread_set_qos_class_self_np(q,0); sleep(1);
  double c1[16], c2[16]; int pl0a=0, pl0b=0; printf("QoS %-10s period %d s: first/second call cpu us:", qn, period);
  for(int i=0;i<n;i++){ sleep(period); pl0a+= curPL()==0; double t0=sk_thread_cpu_us(); sample(); double t1=sk_thread_cpu_us(); sample(); double t2=sk_thread_cpu_us(); pl0b+= curPL()==0; c1[i]=t1-t0; c2[i]=t2-t1; printf(" %.0f/%.0f", c1[i], c2[i]); fflush(stdout); }
  printf("\n   -> first call median %.0f us (=%.2f%% core at this period), back-to-back second call median %.0f us | woke on perflevel0 %d/%d, after %d/%d\n", med(c1,n), med(c1,n)/(period*1e4), med(c2,n), pl0a, n, pl0b, n); fflush(stdout); }

int main(int argc, char** argv){ int hi= argc>1 && !strcmp(argv[1],"hi");
  char model[64]={0}; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0); double la[3]; getloadavg(la,3); time_t now=time(NULL); char ts[32]; strftime(ts,32,"%F %T",localtime(&now));
  printf("model=%s start=%s loadavg=%.2f %.2f %.2f\n", model, ts, la[0],la[1],la[2]);
  SKDT d; sk_read_dt(&d); int n0=(int)sk_sysint("hw.perflevel0.logicalcpu_max");
  for(int i=0;i<d.n;i++){ int same=0; for(int j=0;j<d.n;j++) same+= !strcmp(d.compat[j],d.compat[i]) && !strcmp(d.type[j],d.type[i]); plOfCpu[d.lcid[i]]= same==n0? 0 : 1; }
  pthread_set_qos_class_self_np(QOS_CLASS_UTILITY,0);
  // a) 建订阅拆分（3 次）
  for(int r=0;r<3;r++){
    double t0=sk_thread_cpu_us(), w0=sk_now_s(); CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0);
    double t1=sk_thread_cpu_us(), w1=sk_now_s(); CFMutableDictionaryRef s=NULL; IOReportSubscriptionRef x=IOReportCreateSubscription(NULL,ch,&s,0,NULL);
    double t2=sk_thread_cpu_us(), w2=sk_now_s(); CFDictionaryRef smp=IOReportCreateSamples(x,s,NULL); double t3=sk_thread_cpu_us(), w3=sk_now_s();
    printf("subscribe breakdown #%d (utility): CopyChannelsInGroup cpu %.0f us wall %.0f us | CreateSubscription cpu %.0f us wall %.0f us | first CreateSamples cpu %.0f us wall %.0f us\n",
      r, t1-t0, (w1-w0)*1e6, t2-t1, (w2-w1)*1e6, t3-t2, (w3-w2)*1e6);
    CFRelease(smp); if(r<2){ CFRelease(ch); } else { sub=x; sb=s; } }
  { double t0=sk_thread_cpu_us(); CFMutableDictionaryRef a=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),NULL,0,0,0); double t1=sk_thread_cpu_us(); CFMutableDictionaryRef b=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0); double t2=sk_thread_cpu_us();
    printf("CopyChannelsInGroup(\"CPU Stats\", NULL) cpu %.0f us | CopyChannelsInGroup(\"Energy Model\", NULL) cpu %.0f us\n", t1-t0, t2-t1); (void)a; (void)b; }
  sample();
  if(hi){ run("user-init", QOS_CLASS_USER_INITIATED, 1, 8); run("user-inter", QOS_CLASS_USER_INTERACTIVE, 1, 8); return 0; }
  run("utility", QOS_CLASS_UTILITY, 1, 8);
  run("default", QOS_CLASS_DEFAULT, 1, 8);
  run("background", QOS_CLASS_BACKGROUND, 1, 8);
  run("utility", QOS_CLASS_UTILITY, 5, 3);
  return 0; }
