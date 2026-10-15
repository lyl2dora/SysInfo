// 复核探针 7：「50 ms 单线程主动自检」的可靠性（只读；每次自旋 50 ms，共 20 次，另有一个 50% 占空比的干扰线程
// 最多运行约 2 s）。检查 topo-freq 没覆盖的三点：
//  (1) utility QoS 的自检线程实际落在哪一档（它只能校验所在簇的表）；
//  (2) 参照物用「整进程 ri_cycles / ri_time」时，同进程其他线程（例如启动/唤醒时正忙的主线程）会不会把参照拉偏，
//      对照「仅本线程」的 PROC_PIDTHREADCOUNTS（私有 flavor 34）；
//  (3) 单线程自旋能否区分「实际」与「请求」簇通道（若不能，自检发现不了把请求通道误当实际通道的错误）。
#include "sk.h"
#include <libproc.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <unistd.h>
#include <math.h>
#define PROC_PIDTHREADCOUNTS 34
struct ptcd { uint64_t ins, cyc, ut, st, nj; }; struct ptc { uint16_t len, r0; uint32_t r1; struct ptcd c[8]; };

static int ncpu, npl, clOf[SK_MAXCPU], plOfCl[16], ncl; static uint32_t cid[16]; static char req[16][32], act[16][32]; static double tbl[16][64]; static int nt[16];
static IOReportSubscriptionRef sub; static CFMutableDictionaryRef sb;
static double chF(CFArrayRef arr, int k, int useReq){ const char* name= useReq? req[k]:act[k];
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char nm[32]; sk_cs(IOReportChannelGetChannelName(ch),nm,32); if(strcmp(nm,name)) continue;
    double a=0,f=0; int n=IOReportStateGetCount(ch); for(int s=0;s<n;s++){ char sn[32]; sk_cs(IOReportStateGetNameForIndex(ch,s),sn,32); if(sn[0]=='V'&&sn[1]>='0'&&sn[1]<='9'){ int vi=atoi(sn+1); if(vi<nt[k]){ double r=(double)IOReportStateGetResidency(ch,s); a+=r; f+=r*tbl[k][vi]; } } } return a? f/a:0; } return 0; }

static atomic_int noiseStop;
static void* noise(void* a){ pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0); volatile uint64_t x=0; while(!atomic_load(&noiseStop)){ double t=sk_now_s(); while(sk_now_s()-t<0.002) x++; usleep(2000); } return NULL; }

static void one(int withNoise, double* eProc, double* eThr, double* eReq, int* onPL0pct){
  uint64_t me; pthread_threadid_np(NULL,&me); struct ptc a,b; struct rusage_info_v6 r0,r1; uint64_t onCl[16]={0};
  usleep(3000);
  CFDictionaryRef s1=IOReportCreateSamples(sub,sb,NULL); proc_pid_rusage(getpid(),RUSAGE_INFO_V6,(rusage_info_t*)&r0); memset(&a,0,sizeof a); proc_pidinfo(getpid(),PROC_PIDTHREADCOUNTS,me,&a,sizeof(struct ptc)-(8-npl)*sizeof(struct ptcd));
  uint64_t prev=mach_absolute_time(), end=prev+(uint64_t)(50e6/sk_mach_to_ns()); uint64_t x=0;
  while(1){ for(int k=0;k<20;k++) __asm__ volatile(".rept 100\n add %0, %0, #1\n .endr\n" : "+r"(x)); uint64_t n=mach_absolute_time(); size_t c=0; if(n-prev<(uint64_t)(2e5/sk_mach_to_ns()) && !pthread_cpu_number_np(&c)) onCl[clOf[c]]+=n-prev; prev=n; if(n>end) break; }
  memset(&b,0,sizeof b); proc_pidinfo(getpid(),PROC_PIDTHREADCOUNTS,me,&b,sizeof(struct ptc)-(8-npl)*sizeof(struct ptcd)); proc_pid_rusage(getpid(),RUSAGE_INFO_V6,(rusage_info_t*)&r1); CFDictionaryRef s2=IOReportCreateSamples(sub,sb,NULL);
  CFDictionaryRef d=IOReportCreateSamplesDelta(s1,s2,NULL); CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
  double W=0, FA=0, FR=0, w0=0; for(int k=0;k<ncl;k++) if(onCl[k]){ double fa=chF(arr,k,0), fr=chF(arr,k,1); W+=onCl[k]; FA+=onCl[k]*fa; FR+=onCl[k]*fr; if(plOfCl[k]==0) w0+=onCl[k]; }
  double est=FA/W, estR=FR/W;
  double procF=(double)(r1.ri_cycles-r0.ri_cycles)/(((r1.ri_user_time+r1.ri_system_time)-(r0.ri_user_time+r0.ri_system_time))*sk_mach_to_ns())*1e3;
  double tc=0,tt=0; for(int p=0;p<npl;p++){ tc+=b.c[p].cyc-a.c[p].cyc; tt+=(b.c[p].ut+b.c[p].st-a.c[p].ut-a.c[p].st)*sk_mach_to_ns(); } double thrF= tt? tc/tt*1e3:0;
  *eProc=100*(est-procF)/procF; *eThr=100*(est-thrF)/thrF; *eReq=100*(estR-thrF)/thrF; *onPL0pct=(int)(100*w0/W);
  CFRelease(d); CFRelease(s1); CFRelease(s2); }

int main(void){
  char model[64]={0}; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0); time_t now=time(NULL); char ts[32]; strftime(ts,32,"%F %T",localtime(&now)); printf("model=%s start=%s\n", model, ts);
  SKDT d; sk_read_dt(&d); ncpu=d.n; npl=(int)sk_sysint("hw.nperflevels"); int n0=(int)sk_sysint("hw.perflevel0.logicalcpu_max");
  for(int i=0;i<ncpu;i++){ int k; for(k=0;k<ncl;k++) if(cid[k]==d.cid[i]) break; if(k==ncl){ cid[ncl]=d.cid[i]; int same=0; for(int j=0;j<ncpu;j++) same+= !strcmp(d.compat[j],d.compat[i])&&!strcmp(d.type[j],d.type[i]); plOfCl[ncl]= same==n0? 0:1; ncl++; } clOf[d.lcid[i]]=k; }
  CFMutableDictionaryRef core=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Core Performance States"),0,0,0), cx=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0);
  CFArrayRef ca=CFDictionaryGetValue(core,CFSTR("IOReportChannels")), xa=CFDictionaryGetValue(cx,CFSTR("IOReportChannels"));
  for(int k=0;k<ncl;k++){ int first=-1; for(int c=0;c<ncpu;c++) if(clOf[c]==k){ first=c; break; } char cn[32]; sk_cs(IOReportChannelGetChannelName(CFArrayGetValueAtIndex(ca,first)),cn,32);
    for(CFIndex i=0;i<CFArrayGetCount(xa);i++){ char nm[32]; sk_cs(IOReportChannelGetChannelName(CFArrayGetValueAtIndex(xa,i)),nm,32); if(!strncmp(cn,nm,strlen(nm)) && strlen(nm)>strlen(req[k])) strcpy(req[k],nm); }
    strcpy(act[k],req[k]); char* p=strstr(act[k],"CPU"); if(p) p[2]='M'; }
  { io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &it); io_registry_entry_t pm=IOIteratorNext(it); IOObjectRelease(it); CFMutableDictionaryRef props=NULL; IORegistryEntryCreateCFProperties(pm,&props,NULL,0);
    CFDataRef pd=CFDictionaryGetValue(props,CFSTR("perf-domains")); const uint8_t* b=CFDataGetBytePtr(pd);
    for(int k=0;k<ncl;k++) for(CFIndex o=0;o<CFDataGetLength(pd);o+=28){ char nm[17]={0}; memcpy(nm,b+o+12,16); if(strcmp(nm,req[k])) continue; char kn[64]; snprintf(kn,64,"voltage-states%d-sram",b[o]); CFStringRef K=CFStringCreateWithCString(NULL,kn,kCFStringEncodingUTF8); CFDataRef t=CFDictionaryGetValue(props,K); CFRelease(K);
      int n=(int)(CFDataGetLength(t)/8); const uint32_t* q=(const uint32_t*)CFDataGetBytePtr(t); uint32_t mx=0; for(int j=0;j<n;j++) if(q[2*j]>mx) mx=q[2*j]; double div= mx>=100000000u?1e6:1e3; nt[k]=n; for(int j=0;j<n;j++) tbl[k][j]=q[2*j]/div; } }
  sub=IOReportCreateSubscription(NULL,cx,&sb,0,NULL);
  pthread_set_qos_class_self_np(QOS_CLASS_UTILITY,0);
  for(int withNoise=0; withNoise<2; withNoise++){
    pthread_t nt_; if(withNoise){ atomic_store(&noiseStop,0); pthread_create(&nt_,NULL,noise,NULL); usleep(100000); }
    printf("%s, sampler QoS utility, 50 ms spin x10:\n  err vs whole-process ri_cycles | err vs this-thread counts | request-channel err vs this-thread | sampler time on perflevel0\n", withNoise? "WITH a 50%%-duty USER_INTERACTIVE thread in the same process (simulated busy main thread)":"quiet process");
    for(int r=0;r<10;r++){ double e1,e2,e3; int p0; one(withNoise,&e1,&e2,&e3,&p0); printf("  %+7.2f%% | %+6.2f%% | %+6.2f%% | %3d%%\n", e1, e2, e3, p0); }
    if(withNoise){ atomic_store(&noiseStop,1); pthread_join(nt_,NULL); } }
  return 0; }
