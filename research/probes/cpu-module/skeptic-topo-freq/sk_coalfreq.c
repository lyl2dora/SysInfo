// 复核探针 6（补充能力）：用 resource coalition 全量求和（私有，无需 root；槽位见 audit §1.8，M5 26A428 实测）
// 得到「全系统按 perflevel 拆开的 CPU 时间与 cycles」→ 全系统 perflevel0 / 其余档的平均运行频率，
// 作为 IOReport 实际频率通道的「被动」校验参照（不需要自旋；能在真实多核负载下区分 actual 与 request 通道）。
// 阶段：idle / perflevel0 核数 × UI / 全核 × UTILITY，每段 3 s，全程约 15 s。只读；只结束自己的线程。
#include "sk.h"
#include <dlfcn.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <unistd.h>

typedef int (*cru_fn)(uint64_t, void*, size_t); typedef int (*lc_fn)(int, int, void*, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
#define MAXC 4096
typedef struct { int n; uint64_t cid[MAXC]; uint64_t s[MAXC][50]; } SNAP;
static SNAP A, B; static cru_fn cru; static lc_fn lc;
static void take(SNAP* S){ static struct coalinfo ci[MAXC]; int bytes=lc(2,0,ci,sizeof ci); S->n=bytes/(int)sizeof(struct coalinfo); for(int i=0;i<S->n;i++){ S->cid[i]=ci[i].cid; memset(S->s[i],0,sizeof S->s[i]); cru(ci[i].cid,S->s[i],sizeof S->s[i]); } }
// 槽位：22 cpu_ptime、24..30 cpu_time_eqos（求和 = CPU 时间，mach 单位）、32 cpu_cycles、36 cpu_pcycles
typedef struct { double t, pt, cyc, pcyc; } SYS;
static SYS diff(void){ SYS r={0}; for(int i=0;i<B.n;i++){ int j; for(j=0;j<A.n;j++) if(A.cid[j]==B.cid[i]) break; if(j==A.n) continue;
    double t=0; for(int k=24;k<=30;k++) t+=(double)(B.s[i][k]-A.s[j][k]); r.t+=t; r.pt+=(double)(B.s[i][22]-A.s[j][22]); r.cyc+=(double)(B.s[i][32]-A.s[j][32]); r.pcyc+=(double)(B.s[i][36]-A.s[j][36]); }
  r.t*=sk_mach_to_ns(); r.pt*=sk_mach_to_ns(); return r; }

static atomic_int stopF; static qos_class_t gq;
static void* worker(void* a){ pthread_set_qos_class_self_np(gq,0); uint64_t x=0; while(!atomic_load_explicit(&stopF,memory_order_relaxed)) __asm__ volatile(".rept 100\n add %0, %0, #1\n .endr\n" : "+r"(x)); return NULL; }

int main(void){
  cru=dlsym(RTLD_DEFAULT,"coalition_info_resource_usage"); lc=dlsym(RTLD_DEFAULT,"proc_listcoalitions"); if(!cru||!lc){ printf("coalition symbols missing\n"); return 1; }
  char model[64]={0}; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0); time_t now=time(NULL); char ts[32]; strftime(ts,32,"%F %T",localtime(&now)); double la[3]; getloadavg(la,3);
  printf("model=%s start=%s loadavg=%.2f %.2f %.2f\n", model, ts, la[0],la[1],la[2]);
  // 拓扑（最简：同 compat+type 的核数 == perflevel0.logicalcpu_max 即 perflevel0）；簇通道 = CPU/CPM 名（本探针只做对照，不是发现算法）
  SKDT d; sk_read_dt(&d); int ncpu=d.n, n0=(int)sk_sysint("hw.perflevel0.logicalcpu_max"); int pl0[SK_MAXCPU];
  for(int i=0;i<ncpu;i++){ int same=0; for(int j=0;j<ncpu;j++) same+= !strcmp(d.compat[j],d.compat[i]) && !strcmp(d.type[j],d.type[i]); pl0[d.lcid[i]]= same==n0; }
  // 簇 → cpu 列表，与 IOReport 请求/实际通道和表（perf-domains）
  int ncl=0; uint32_t cid[16]; int clOf[SK_MAXCPU]; for(int i=0;i<ncpu;i++){ int k; for(k=0;k<ncl;k++) if(cid[k]==d.cid[i]) break; if(k==ncl) cid[ncl++]=d.cid[i]; clOf[d.lcid[i]]=k; }
  CFMutableDictionaryRef core=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Core Performance States"),0,0,0); CFMutableDictionaryRef cx=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0);
  CFArrayRef ca=CFDictionaryGetValue(core,CFSTR("IOReportChannels")), xa=CFDictionaryGetValue(cx,CFSTR("IOReportChannels"));
  char req[16][32]={{0}}, act[16][32]={{0}}; double tbl[16][64]; int nt[16]={0};
  for(int k=0;k<ncl;k++){ int first=-1; for(int c=0;c<ncpu;c++) if(clOf[c]==k){ first=c; break; } char cn[32]; sk_cs(IOReportChannelGetChannelName(CFArrayGetValueAtIndex(ca,first)),cn,32);
    for(CFIndex i=0;i<CFArrayGetCount(xa);i++){ char nm[32]; sk_cs(IOReportChannelGetChannelName(CFArrayGetValueAtIndex(xa,i)),nm,32); if(!strncmp(cn,nm,strlen(nm)) && strlen(nm)>strlen(req[k])) strcpy(req[k],nm); }
    strcpy(act[k],req[k]); char* p=strstr(act[k],"CPU"); if(p) p[2]='M'; }
  { io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &it); io_registry_entry_t pm=IOIteratorNext(it); IOObjectRelease(it); CFMutableDictionaryRef props=NULL; IORegistryEntryCreateCFProperties(pm,&props,NULL,0);
    CFDataRef pd=CFDictionaryGetValue(props,CFSTR("perf-domains")); const uint8_t* b=CFDataGetBytePtr(pd);
    for(int k=0;k<ncl;k++) for(CFIndex o=0;o<CFDataGetLength(pd);o+=28){ char nm[17]={0}; memcpy(nm,b+o+12,16); if(strcmp(nm,req[k])) continue; char kn[64]; snprintf(kn,64,"voltage-states%d-sram",b[o]); CFStringRef K=CFStringCreateWithCString(NULL,kn,kCFStringEncodingUTF8); CFDataRef t=CFDictionaryGetValue(props,K); CFRelease(K);
      int n=(int)(CFDataGetLength(t)/8); const uint32_t* q=(const uint32_t*)CFDataGetBytePtr(t); uint32_t mx=0; for(int j=0;j<n;j++) if(q[2*j]>mx) mx=q[2*j]; double div= mx>=100000000u?1e6:1e3; nt[k]=n; for(int j=0;j<n;j++) tbl[k][j]=q[2*j]/div; } }
  IOReportMergeChannels(cx,core,NULL); CFMutableDictionaryRef sb=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,cx,&sb,0,NULL);
  for(int k=0;k<ncl;k++) printf("cluster %u: req=%s act=%s table n=%d pl0=%d\n", cid[k], req[k], act[k], nt[k], ({int r=0; for(int c=0;c<ncpu;c++) if(clOf[c]==k) r=pl0[c]; r;}));
  { double t0=sk_thread_cpu_us(); take(&A); printf("coalition scan: %d coalitions, cpu %.0f us\n", A.n, sk_thread_cpu_us()-t0); }

  struct { const char* nm; qos_class_t q; int n; } ph[]={{"idle",QOS_CLASS_DEFAULT,0},{"perflevel0 x UI",QOS_CLASS_USER_INTERACTIVE,n0},{"all x UTILITY",QOS_CLASS_UTILITY,ncpu}};
  for(int p=0;p<3;p++){
    gq=ph[p].q; atomic_store(&stopF,0); pthread_t th[SK_MAXCPU]; for(int i=0;i<ph[p].n;i++) pthread_create(&th[i],NULL,worker,NULL); usleep(500000);
    uint64_t t0[SK_MAXCPU][4], t1[SK_MAXCPU][4]; take(&A); sk_ticks(t0); CFDictionaryRef s1=IOReportCreateSamples(sub,sb,NULL); sleep(3); CFDictionaryRef s2=IOReportCreateSamples(sub,sb,NULL); sk_ticks(t1); take(&B);
    atomic_store(&stopF,1); for(int i=0;i<ph[p].n;i++) pthread_join(th[i],NULL);
    SYS s=diff(); CFDictionaryRef dd=IOReportCreateSamplesDelta(s1,s2,NULL); CFArrayRef arr=CFDictionaryGetValue(dd,CFSTR("IOReportChannels"));
    // IOReport：每簇 actual/request 频率，按该簇忙碌 tick 加权到 perflevel
    double wA[2]={0}, wR[2]={0}, w[2]={0}, busyT=0;
    for(int k=0;k<ncl;k++){ double fa=0,fr=0; for(int which=0;which<2;which++){ const char* name= which? req[k]:act[k];
        for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char nm[32], sg[96]; sk_cs(IOReportChannelGetChannelName(ch),nm,32); sk_cs(IOReportChannelGetSubGroup(ch),sg,96); if(strcmp(nm,name)||strcmp(sg,"CPU Complex Performance States")) continue;
          double a=0,f=0; int n=IOReportStateGetCount(ch); for(int st=0;st<n;st++){ char sn[32]; sk_cs(IOReportStateGetNameForIndex(ch,st),sn,32); if(sn[0]=='V' && sn[1]>='0' && sn[1]<='9'){ int vi=atoi(sn+1); if(vi<nt[k]){ double r=(double)IOReportStateGetResidency(ch,st); a+=r; f+=r*tbl[k][vi]; } } }
          if(which) fr= a? f/a:0; else fa= a? f/a:0; } }
      double busy=0; int isP0=0; for(int c=0;c<ncpu;c++) if(clOf[c]==k){ busy+=(t1[c][0]-t0[c][0])+(t1[c][1]-t0[c][1])+(t1[c][3]-t0[c][3]); isP0=pl0[c]; }
      int L= isP0? 0:1; wA[L]+=busy*fa; wR[L]+=busy*fr; w[L]+=busy; busyT+=busy*10e6; }
    double f0= s.pt? s.pcyc/s.pt*1e3:0, f1= (s.t-s.pt)>0? (s.cyc-s.pcyc)/(s.t-s.pt)*1e3:0;
    printf("\n== %s (%d threads, 3 s) ==\n system CPU time from coalitions %.2f core-s (ticks say %.2f core-s); perflevel0 share %.1f%%\n", ph[p].nm, ph[p].n, s.t/1e9, busyT/1e9, s.t? 100*s.pt/s.t:0);
    printf("  perflevel0: coalition cycles/time %4.0f MHz | IOReport busy-weighted actual %4.0f (%+.1f%%) request %4.0f (%+.1f%%)\n", f0, w[0]?wA[0]/w[0]:0, (f0&&w[0])?100*(wA[0]/w[0]-f0)/f0:0, w[0]?wR[0]/w[0]:0, (f0&&w[0])?100*(wR[0]/w[0]-f0)/f0:0);
    printf("  other lvls: coalition cycles/time %4.0f MHz | IOReport busy-weighted actual %4.0f (%+.1f%%) request %4.0f (%+.1f%%)\n", f1, w[1]?wA[1]/w[1]:0, (f1&&w[1])?100*(wA[1]/w[1]-f1)/f1:0, w[1]?wR[1]/w[1]:0, (f1&&w[1])?100*(wR[1]/w[1]-f1)/f1:0);
    CFRelease(dd); CFRelease(s1); CFRelease(s2); sleep(1); }
  return 0; }
