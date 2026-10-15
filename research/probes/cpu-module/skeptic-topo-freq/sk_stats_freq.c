// 复核探针：按 Stats（~/Documents/stats，06c4dc1f）FrequencyReader 的节奏测 CPU 频率采样开销，作 C4 对照（只读；单线程；几乎都在 sleep）。
//  Stats：订阅「CPU Complex Performance States」+「CPU Core Performance States」合并；面板可见时每 interval（默认 1 s）一次 read，
//         每次 read 先取 1 个初始样本，再每 125 ms 取 1 个、共 4 个，做 4 次 delta（每次 read 5 次 CreateSamples）。
//  对照：本方案只订阅 Complex（CPM），每周期 1 次 CreateSamples + 1 次 delta。
//  本探针是 C 实现，不含 Stats 的 Swift 字符串转换，所以 Stats 一栏是下限。
// 用法：sk_stats_freq [bg|utility] [秒数=20]
#include "sk.h"
#include <pthread.h>
#include <pthread/qos.h>
#include <unistd.h>

static int cmpd(const void* a, const void* b){ double x=*(double*)a, y=*(double*)b; return x<y?-1:x>y; }
static double med(double* v, int n){ double t[128]; memcpy(t,v,n*sizeof(double)); qsort(t,n,sizeof(double),cmpd); return n%2? t[n/2] : (t[n/2-1]+t[n/2])/2; }

static void consume(CFDictionaryRef d){ CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); volatile int64_t s=0;
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); int n=IOReportStateGetCount(ch); for(int k=0;k<n;k++) s+=IOReportStateGetResidency(ch,k); } }

int main(int argc, char** argv){
  const char* q= argc>1? argv[1] : "bg"; int secs= argc>2? atoi(argv[2]) : 20; if(secs>60) secs=60;
  pthread_set_qos_class_self_np(!strcmp(q,"utility")? QOS_CLASS_UTILITY : QOS_CLASS_BACKGROUND, 0);
  char model[64]={0}; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0); double la[3]; getloadavg(la,3);
  printf("model=%s qos=%s secs=%d loadavg=%.2f %.2f %.2f\n", model, q, secs, la[0],la[1],la[2]);

  // Stats 式订阅
  CFMutableDictionaryRef a=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0);
  CFMutableDictionaryRef b=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Core Performance States"),0,0,0);
  IOReportMergeChannels(a,b,NULL); CFMutableDictionaryRef sa=NULL; IOReportSubscriptionRef subA=IOReportCreateSubscription(NULL,a,&sa,0,NULL);
  // 本方案订阅
  CFMutableDictionaryRef c=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0);
  CFMutableDictionaryRef sc=NULL; IOReportSubscriptionRef subC=IOReportCreateSubscription(NULL,c,&sc,0,NULL);
  printf("channels: stats-style %ld, complex-only %ld\n", (long)CFArrayGetCount(CFDictionaryGetValue(sa,CFSTR("IOReportChannels"))), (long)CFArrayGetCount(CFDictionaryGetValue(sc,CFSTR("IOReportChannels"))));

  // A) Stats 节奏：每 1 s 一次 read（5 次采样 + 4 次 delta，间隔 125 ms）
  double ra[128]; int na=0; CFDictionaryRef prevA=NULL; double w0=sk_now_s();
  while(sk_now_s()-w0 < secs && na<128){
    double t0=sk_thread_cpu_us();
    CFDictionaryRef init=IOReportCreateSamples(subA,sa,NULL); CFDictionaryRef p= prevA? prevA : init; if(prevA) CFRelease(init);
    double tsleep=0;
    for(int i=0;i<4;i++){ double s0=sk_thread_cpu_us(); usleep(125000); tsleep+=sk_thread_cpu_us()-s0;
      CFDictionaryRef nx=IOReportCreateSamples(subA,sa,NULL); CFDictionaryRef d=IOReportCreateSamplesDelta(p,nx,NULL); consume(d); CFRelease(d); CFRelease(p); p=nx; }
    prevA=p; ra[na++]= sk_thread_cpu_us()-t0-tsleep;
    usleep(500000);
  }
  // B) 本方案：每 1 s 一次 CreateSamples + delta
  double rc[128]; int nc=0; CFDictionaryRef prevC=IOReportCreateSamples(subC,sc,NULL); w0=sk_now_s();
  while(sk_now_s()-w0 < secs && nc<128){ sleep(1); double t0=sk_thread_cpu_us();
    CFDictionaryRef nx=IOReportCreateSamples(subC,sc,NULL); CFDictionaryRef d=IOReportCreateSamplesDelta(prevC,nx,NULL); consume(d); CFRelease(d); CFRelease(prevC); prevC=nx;
    rc[nc++]=sk_thread_cpu_us()-t0; }

  printf("A stats-style   per 1 s read: median %.2f ms (n=%d) => %.2f%% single core while panel open\n", med(ra,na)/1000, na, med(ra,na)/1e4);
  printf("B complex-only  per 1 s     : median %.2f ms (n=%d) => %.2f%% at 1 s, %.2f%% at 5 s\n", med(rc,nc)/1000, nc, med(rc,nc)/1e4, med(rc,nc)/5e4);
  return 0;
}
