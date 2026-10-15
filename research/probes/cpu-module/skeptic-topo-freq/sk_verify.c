// 复核探针 2：频率与拓扑映射的独立实测（两台机器通用；5 个阶段，每段加载约 3.5 s，全程约 30 s）。
//
// 与 topo-freq/freq_verify.c 的区别（刻意换参照物与方法）：
//  - 频率参照：PROC_PIDTHREADCOUNTS（proc_pidinfo 私有 flavor 34）给出每个工作线程「按 perflevel 拆开」的
//    cycles 与 CPU 时间（内核 recount），直接得到每档的真实平均频率；不依赖 pthread_cpu_number_np 采样，
//    也不写死 timebase（用 mach_timebase_info）。另用公开的 rusage v6 ri_pcycles/ri_*_ptime 交叉核对。
//  - 线程落点：工作线程按「时间」而不是按「迭代次数」记录所在 cpu（每次检查累加 mach_absolute_time 差值），
//    避免样本数与频率成正比带来的偏置。
//  - 通道映射：请求簇通道 = 本簇逐核通道名的最长公共前缀；实际簇通道用两条规则分别求（topo-freq 的
//    「等长差一字符 + 状态名相同 + 非逐核前缀」与简单的「CPU→CPM 替换」），不一致就报告。
//  - 表映射：perf-domains 域名匹配与 acc-clusters（有则用）两条独立路径，不一致就报告。
//  - 核号映射：逐核 tick 忙碌增量（减去 idle 阶段基线）与线程时间直方图做逐核对照。
// 只读；只结束自己的线程。
#include "sk.h"
#include <libproc.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <unistd.h>
#include <math.h>

#ifndef PROC_PIDTHREADCOUNTS
#define PROC_PIDTHREADCOUNTS 34
struct proc_threadcounts_data { uint64_t ptcd_instructions, ptcd_cycles, ptcd_user_time_mach, ptcd_system_time_mach, ptcd_energy_nj; };
struct proc_threadcounts { uint16_t ptc_len; uint16_t ptc_reserved0; uint32_t ptc_reserved1; struct proc_threadcounts_data ptc_counts[]; };
#endif

#define MAXCL 16
static int ncpu, ncl, npl; static int cpuCl[SK_MAXCPU]; static int plOfCl[MAXCL];
static struct { uint32_t die, id; int n; int cpus[64]; char type[8], compat[40]; uint32_t l2; char coreCh[64][32]; char req[32], act1[32], act2[32]; int keyPD, keyACC; double tbl[64]; int ntbl; } cl[MAXCL];
static struct { char name[32]; int logical, cpusperl2; long long l2; } pl[8];

// ---------- 发现 ----------
static void discover(void){
  npl=(int)sk_sysint("hw.nperflevels");
  for(int p=0;p<npl;p++){ char k[64]; size_t s=32; snprintf(k,64,"hw.perflevel%d.name",p); sysctlbyname(k,pl[p].name,&s,NULL,0);
    snprintf(k,64,"hw.perflevel%d.logicalcpu_max",p); pl[p].logical=(int)sk_sysint(k); snprintf(k,64,"hw.perflevel%d.cpusperl2",p); pl[p].cpusperl2=(int)sk_sysint(k); snprintf(k,64,"hw.perflevel%d.l2cachesize",p); pl[p].l2=sk_sysint(k); }
  SKDT d; sk_read_dt(&d); ncpu=d.n; ncl=0;
  for(int i=0;i<d.n;i++){ int k; for(k=0;k<ncl;k++) if(cl[k].die==d.die[i] && cl[k].id==d.cid[i]) break;
    if(k==ncl){ memset(&cl[k],0,sizeof cl[k]); cl[k].die=d.die[i]; cl[k].id=d.cid[i]; strcpy(cl[k].type,d.type[i]); strcpy(cl[k].compat,d.compat[i]); cl[k].l2=d.l2[i]; cl[k].keyPD=cl[k].keyACC=-1; ncl++; }
    cl[k].cpus[cl[k].n++]=d.lcid[i]; cpuCl[d.lcid[i]]=k; }
  // perflevel：这里用「核数 + 簇大小」唯一匹配（与 topo-freq 的 a 法相同）；实测部分再用内核按档计时独立核对
  for(int k=0;k<ncl;k++){ plOfCl[k]=-1; int tot=0; for(int j=0;j<ncl;j++) if(!strcmp(cl[j].compat,cl[k].compat) && !strcmp(cl[j].type,cl[k].type)) tot+=cl[j].n;
    int cand=-1,nc=0; for(int p=0;p<npl;p++) if(pl[p].logical==tot && pl[p].cpusperl2==cl[k].n){ cand=p; nc++; } if(nc==1) plOfCl[k]=cand; }
}

static char coreChans[SK_MAXCPU][32]; static int ncoreCh; static char cxChans[64][32]; static char cxStates[64][600]; static int ncx;
static IOReportSubscriptionRef sub; static CFMutableDictionaryRef subbed;
static int isV(const char* s){ return s[0]=='V' && s[1]>='0' && s[1]<='9'; }
static void mapChannels(void){
  CFMutableDictionaryRef a=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Core Performance States"),0,0,0);
  IOReportMergeChannels(a, IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0), NULL);
  sub=IOReportCreateSubscription(NULL,a,&subbed,0,NULL);
  CFDictionaryRef s=IOReportCreateSamples(sub,subbed,NULL); CFArrayRef arr=CFDictionaryGetValue(s,CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char sg[96], nm[32]; sk_cs(IOReportChannelGetSubGroup(ch),sg,96); sk_cs(IOReportChannelGetChannelName(ch),nm,32);
    if(!strcmp(sg,"CPU Core Performance States")) strcpy(coreChans[ncoreCh++],nm);
    else if(!strcmp(sg,"CPU Complex Performance States")){ strcpy(cxChans[ncx],nm); cxStates[ncx][0]=0; int n=IOReportStateGetCount(ch); for(int k=0;k<n;k++){ char st[32]; sk_cs(IOReportStateGetNameForIndex(ch,k),st,32); strncat(cxStates[ncx],st,590-strlen(cxStates[ncx])); strcat(cxStates[ncx],","); } ncx++; } }
  CFRelease(s);
  for(int k=0;k<ncl;k++){ for(int j=0;j<cl[k].n;j++) strcpy(cl[k].coreCh[j], cl[k].cpus[j]<ncoreCh? coreChans[cl[k].cpus[j]] : "?");
    int best=-1; for(int x=0;x<ncx;x++){ size_t L=strlen(cxChans[x]); int all=1; for(int j=0;j<cl[k].n;j++) if(strncmp(cl[k].coreCh[j],cxChans[x],L)) all=0; if(all && (best<0||L>strlen(cxChans[best]))) best=x; }
    if(best<0) continue; strcpy(cl[k].req,cxChans[best]);
    // 规则 1（topo-freq）：等长、只差一字符、状态名相同、不是任何逐核通道名的前缀
    for(int x=0;x<ncx;x++){ if(x==best || strlen(cxChans[x])!=strlen(cxChans[best]) || strcmp(cxStates[x],cxStates[best])) continue; int diff=0; for(size_t q=0;q<strlen(cxChans[x]);q++) diff+= cxChans[x][q]!=cxChans[best][q];
      int pre=0; for(int y=0;y<ncoreCh;y++) if(!strncmp(coreChans[y],cxChans[x],strlen(cxChans[x]))) pre=1; if(diff==1 && !pre){ strcpy(cl[k].act1,cxChans[x]); break; } }
    // 规则 2：把请求名里的 "CPU" 换成 "CPM"
    char* p=strstr(cl[k].req,"CPU"); if(p){ char t[32]; strcpy(t,cl[k].req); t[p-cl[k].req+2]='M'; for(int x=0;x<ncx;x++) if(!strcmp(cxChans[x],t)) strcpy(cl[k].act2,t); } }
}

static void mapTables(void){
  io_iterator_t it; if(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &it)) return; io_registry_entry_t pm=IOIteratorNext(it); IOObjectRelease(it); if(!pm) return;
  CFMutableDictionaryRef props=NULL; IORegistryEntryCreateCFProperties(pm,&props,NULL,0); IOObjectRelease(pm);
  CFDataRef pd=CFDictionaryGetValue(props,CFSTR("perf-domains")); CFDataRef ac=CFDictionaryGetValue(props,CFSTR("acc-clusters"));
  for(int k=0;k<ncl;k++){
    if(pd && CFDataGetLength(pd)%28==0){ const uint8_t* b=CFDataGetBytePtr(pd); for(CFIndex o=0;o<CFDataGetLength(pd);o+=28){ char nm[17]={0}; memcpy(nm,b+o+12,16); if(!strcmp(nm,cl[k].req)) cl[k].keyPD=b[o]; } }
    if(ac && CFDataGetLength(ac)%8==0){ const uint8_t* b=CFDataGetBytePtr(ac); for(CFIndex o=0;o<CFDataGetLength(ac);o+=8) if(b[o+1]==cl[k].id) cl[k].keyACC=b[o]; }
    int key= cl[k].keyPD>=0? cl[k].keyPD : cl[k].keyACC; if(key<0) continue;
    char kn[64]; snprintf(kn,64,"voltage-states%d-sram",key); CFStringRef K=CFStringCreateWithCString(NULL,kn,kCFStringEncodingUTF8); CFDataRef t=CFDictionaryGetValue(props,K); CFRelease(K);
    if(!t) continue; int n=(int)(CFDataGetLength(t)/8); const uint32_t* q=(const uint32_t*)CFDataGetBytePtr(t); uint32_t mx=0; for(int j=0;j<n;j++) if(q[2*j]>mx) mx=q[2*j];
    double div= mx>=100000000u? 1e6 : 1e3; cl[k].ntbl=n; for(int j=0;j<n;j++) cl[k].tbl[j]=q[2*j]/div; }
  CFRelease(props);
}

// ---------- 负载 ----------
static atomic_int stopF; static qos_class_t gq; static int gN;
static uint64_t tid[SK_MAXCPU]; static uint64_t onCpuMach[SK_MAXCPU][SK_MAXCPU];
static void* worker(void* arg){ int id=(int)(long)arg; pthread_set_qos_class_self_np(gq,0); pthread_threadid_np(NULL,&tid[id]); memset(onCpuMach[id],0,sizeof onCpuMach[id]);
  uint64_t x=0, prev=mach_absolute_time(); const uint64_t cap=(uint64_t)(200000.0/sk_mach_to_ns()); // >200 µs 视为被抢占，不计入
  while(!atomic_load_explicit(&stopF,memory_order_relaxed)){ for(int k=0;k<50;k++) __asm__ volatile(".rept 100\n add %0, %0, #1\n .endr\n" : "+r"(x));
    uint64_t now=mach_absolute_time(); size_t c=0; if(now-prev<cap && !pthread_cpu_number_np(&c) && c<SK_MAXCPU) onCpuMach[id][c]+=now-prev; prev=now; }
  return NULL; }
typedef struct { double cyc[8], tm[8]; int ok; } TC;
static TC threadCounts(int n){ TC r; memset(&r,0,sizeof r); size_t sz=sizeof(struct proc_threadcounts)+npl*sizeof(struct proc_threadcounts_data); struct proc_threadcounts* b=calloc(1,sz); r.ok=1;
  for(int i=0;i<n;i++){ memset(b,0,sz); int got=proc_pidinfo(getpid(),PROC_PIDTHREADCOUNTS,tid[i],b,(int)sz); if(got<=0){ r.ok=0; continue; }
    for(int p=0;p<npl;p++){ r.cyc[p]+=b->ptc_counts[p].ptcd_cycles; r.tm[p]+=(b->ptc_counts[p].ptcd_user_time_mach+b->ptc_counts[p].ptcd_system_time_mach)*sk_mach_to_ns(); } }
  free(b); return r; }
typedef struct { double cyc, pcyc, t, pt; } RU;
static RU ru(void){ struct rusage_info_v6 r; RU o={0}; if(!proc_pid_rusage(getpid(),RUSAGE_INFO_V6,(rusage_info_t*)&r)){ o.cyc=r.ri_cycles; o.pcyc=r.ri_pcycles; o.t=(r.ri_user_time+r.ri_system_time)*sk_mach_to_ns(); o.pt=(r.ri_user_ptime+r.ri_system_ptime)*sk_mach_to_ns(); } return o; }

static void chanFreq(CFArrayRef arr, const char* name, const double* tbl, int ntbl, double* act, double* mhz){
  *act=0; *mhz=0; if(!name[0]) return;
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char nm[32]; sk_cs(IOReportChannelGetChannelName(ch),nm,32); char sg[96]; sk_cs(IOReportChannelGetSubGroup(ch),sg,96);
    if(strcmp(nm,name) || strcmp(sg,"CPU Complex Performance States")) continue;
    int n=IOReportStateGetCount(ch); double tot=0,a=0,f=0; for(int k=0;k<n;k++){ char st[32]; sk_cs(IOReportStateGetNameForIndex(ch,k),st,32); double r=(double)IOReportStateGetResidency(ch,k); tot+=r; if(isV(st)){ int vi=atoi(st+1); if(vi<ntbl){ a+=r; f+=r*tbl[vi]; } } }
    *act= tot? a/tot:0; *mhz= a? f/a:0; return; } }
static double coreActive(CFArrayRef arr, const char* name){
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char nm[32]; sk_cs(IOReportChannelGetChannelName(ch),nm,32); char sg[96]; sk_cs(IOReportChannelGetSubGroup(ch),sg,96);
    if(strcmp(nm,name) || strcmp(sg,"CPU Core Performance States")) continue; int n=IOReportStateGetCount(ch); double tot=0,a=0; for(int k=0;k<n;k++){ char st[32]; sk_cs(IOReportStateGetNameForIndex(ch,k),st,32); double r=(double)IOReportStateGetResidency(ch,k); tot+=r; if(isV(st)) a+=r; } return tot? 100*a/tot:0; }
  return -1; }

static double baseBusy[SK_MAXCPU];
int main(int argc, char** argv){
  double win= argc>1? atof(argv[1]) : 3.0;
  char model[64]={0}; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0); char build[32]={0}; size_t bs=32; sysctlbyname("kern.osversion",build,&bs,NULL,0);
  time_t now=time(NULL); char ts[32]; strftime(ts,32,"%F %T",localtime(&now)); double la[3]; getloadavg(la,3);
  printf("model=%s build=%s start=%s loadavg=%.2f %.2f %.2f\n", model, build, ts, la[0],la[1],la[2]);
  discover(); mapChannels(); mapTables();
  for(int p=0;p<npl;p++) printf("perflevel%d %s logical=%d cpusperl2=%d\n", p, pl[p].name, pl[p].logical, pl[p].cpusperl2);
  for(int k=0;k<ncl;k++) printf("cluster die%u/id%u type=%s %s cpus %d..%d -> perflevel%d | core ch %s..%s | req=%s act(rule1)=%s act(CPU->CPM)=%s %s | table key perf-domains=%d acc-clusters=%d n=%d %.0f..%.0f MHz\n",
    cl[k].die, cl[k].id, cl[k].type, cl[k].compat, cl[k].cpus[0], cl[k].cpus[cl[k].n-1], plOfCl[k], cl[k].coreCh[0], cl[k].coreCh[cl[k].n-1], cl[k].req, cl[k].act1, cl[k].act2, strcmp(cl[k].act1,cl[k].act2)?"<<MISMATCH":"(agree)", cl[k].keyPD, cl[k].keyACC, cl[k].ntbl, cl[k].ntbl?cl[k].tbl[0]:0, cl[k].ntbl?cl[k].tbl[cl[k].ntbl-1]:0);
  printf("counts: DT=%d IOReport core ch=%d hw.logicalcpu_max=%lld\n", ncpu, ncoreCh, sk_sysint("hw.logicalcpu_max"));

  int n0=pl[0].logical, nlast=pl[npl-1].cpusperl2;
  struct { const char* nm; qos_class_t q; int n; } ph[]={ {"idle",QOS_CLASS_DEFAULT,0}, {"1xUI",QOS_CLASS_USER_INTERACTIVE,1}, {"perflevel0-cores xUI",QOS_CLASS_USER_INTERACTIVE,n0}, {"all-cores xUTILITY",QOS_CLASS_UTILITY,ncpu}, {"last-level-cluster xBACKGROUND",QOS_CLASS_BACKGROUND,nlast} };
  for(int p=0;p<5;p++){
    gq=ph[p].q; gN=ph[p].n; atomic_store(&stopF,0); pthread_t th[SK_MAXCPU]; for(int i=0;i<gN;i++) pthread_create(&th[i],NULL,worker,(void*)(long)i);
    usleep(500000);
    uint64_t t0[SK_MAXCPU][4], t1[SK_MAXCPU][4]; uint64_t h0[SK_MAXCPU][SK_MAXCPU]; TC c0=threadCounts(gN); RU r0=ru(); memcpy(h0,onCpuMach,sizeof h0); sk_ticks(t0); CFDictionaryRef s1=IOReportCreateSamples(sub,subbed,NULL);
    usleep((useconds_t)(win*1e6));
    CFDictionaryRef s2=IOReportCreateSamples(sub,subbed,NULL); sk_ticks(t1); TC c1=threadCounts(gN); RU r1=ru(); uint64_t h1[SK_MAXCPU][SK_MAXCPU]; memcpy(h1,onCpuMach,sizeof h1);
    atomic_store(&stopF,1); for(int i=0;i<gN;i++) pthread_join(th[i],NULL);
    now=time(NULL); strftime(ts,32,"%T",localtime(&now)); printf("\n== phase %s: %d threads (window %.1f s, ended %s) ==\n", ph[p].nm, gN, win, ts);
    CFDictionaryRef dd=IOReportCreateSamplesDelta(s1,s2,NULL); CFArrayRef arr=CFDictionaryGetValue(dd,CFSTR("IOReportChannels"));
    // 线程按时间落在各 cpu / 簇 / perflevel
    double onCpu[SK_MAXCPU]={0}, onCl[MAXCL]={0}, onPL[8]={0}, tot=0;
    for(int i=0;i<gN;i++) for(int c=0;c<ncpu;c++){ double v=(double)(h1[i][c]-h0[i][c])*sk_mach_to_ns(); onCpu[c]+=v; onCl[cpuCl[c]]+=v; if(plOfCl[cpuCl[c]]>=0) onPL[plOfCl[cpuCl[c]]]+=v; tot+=v; }
    // 每核 busy
    double busy[SK_MAXCPU];
    for(int c=0;c<ncpu;c++){ double u=(t1[c][0]-t0[c][0])+(t1[c][1]-t0[c][1])+(t1[c][3]-t0[c][3]), id=t1[c][2]-t0[c][2]; busy[c]= u+id? 100*u/(u+id):0; if(p==0) baseBusy[c]=busy[c]; }
    // 簇
    double actF[MAXCL], reqF[MAXCL];
    for(int k=0;k<ncl;k++){ double aA,mA,aR,mR; chanFreq(arr,cl[k].act1[0]?cl[k].act1:cl[k].act2,cl[k].tbl,cl[k].ntbl,&aA,&mA); chanFreq(arr,cl[k].req,cl[k].tbl,cl[k].ntbl,&aR,&mR); actF[k]=mA; reqF[k]=mR;
      double b=0; for(int j=0;j<cl[k].n;j++) b+=busy[cl[k].cpus[j]]; b/=cl[k].n;
      printf(" cluster%u(pl%d): mean core busy %5.1f%% | actual %-6s active %5.1f%% @ %4.0f MHz | request %-6s active %5.1f%% @ %4.0f MHz | threads here %5.1f%% of time\n", cl[k].id, plOfCl[k], b, cl[k].act1, 100*aA, mA, cl[k].req, 100*aR, mR, tot? 100*onCl[k]/tot:0); }
    if(gN){
      // 按 perflevel：内核 per-thread counts 与我方映射 + IOReport 估计
      for(int q=0;q<npl;q++){ double kt=c1.tm[q]-c0.tm[q], kc=c1.cyc[q]-c0.cyc[q]; double ktot=0; for(int z=0;z<npl;z++) ktot+=c1.tm[z]-c0.tm[z];
        double estA=0, estR=0, wt=0; for(int k=0;k<ncl;k++) if(plOfCl[k]==q && onCl[k]>0 && actF[k]>0){ estA+=onCl[k]*actF[k]; estR+=onCl[k]*reqF[k]; wt+=onCl[k]; }
        double kf= kt>0? kc/kt*1e3 : 0; // cycles/ns*1000 = MHz
        printf("  perflevel%d %-12s kernel(thread counts): %5.1f%% of time, %4.0f MHz | our map: %5.1f%% of time | IOReport actual %4.0f MHz (%+.2f%%) request %4.0f MHz (%+.2f%%)\n",
          q, pl[q].name, ktot? 100*kt/ktot:0, kf, tot? 100*onPL[q]/tot:0, wt? estA/wt:0, (wt&&kf)? 100*(estA/wt-kf)/kf:0, wt? estR/wt:0, (wt&&kf)? 100*(estR/wt-kf)/kf:0); }
      if(!c1.ok) printf("  (PROC_PIDTHREADCOUNTS failed for some threads)\n");
      double pt=r1.pt-r0.pt, t=r1.t-r0.t; printf("  cross-check rusage v6 (whole process): perflevel0 share %.1f%%, perflevel0 %4.0f MHz, other %4.0f MHz\n", t? 100*pt/t:0, pt? (r1.pcyc-r0.pcyc)/pt*1e3:0, (t-pt)>0? ((r1.cyc-r0.cyc)-(r1.pcyc-r0.pcyc))/(t-pt)*1e3:0);
      // 逐核对照：线程时间占比 vs tick 忙碌增量（减 idle 基线）vs IOReport 逐核通道活跃%
      printf("  per-core  thread-time%% / tick-busy%% (minus idle baseline) / IOReport core ch active%%:\n   ");
      double sx=0,sy=0,sxx=0,syy=0,sxy=0; int agree=0, hot=0;
      for(int c=0;c<ncpu;c++){ double x=100*onCpu[c]/(win*1e9), y=busy[c]-baseBusy[c]; double ia=coreActive(arr,coreChans[c]); printf(" %d:%.0f/%.0f/%.0f", c, x, y, ia); sx+=x; sy+=y; sxx+=x*x; syy+=y*y; sxy+=x*y; if(x>50){ hot++; if(y>30) agree++; } }
      double nn=ncpu, r=(nn*sxy-sx*sy)/sqrt((nn*sxx-sx*sx)*(nn*syy-sy*sy)); printf("\n   Pearson r(thread-time, tick-busy increase)=%.3f; cores with thread-time>50%%: %d, of which tick increase>30pp: %d\n", r, hot, agree); }
    else { printf("  per-core tick-busy%% / IOReport core ch active%%:"); for(int c=0;c<ncpu;c++) printf(" %d:%.0f/%.0f", c, busy[c], coreActive(arr,coreChans[c])); printf("\n"); }
    CFRelease(dd); CFRelease(s1); CFRelease(s2); sleep(1);
  }
  return 0; }
