// 拓扑与 DVFS 表的运行时发现（探针版参考实现，两台机器通用）。
//
// 原则（D20、CLAUDE.md）：不写死通道名、pmgr 表键号、核类型字母；只用以下几条「语法」：
// - IODeviceTree:/cpus 的子节点有 logical-cpu-id、cluster-id、compatible、l2-cache-size；
// - IOReport "CPU Stats" 组的两个子组名 "CPU Core Performance States"（逐核）与
//   "CPU Complex Performance States"（逐簇），状态名语法 DOWN / IDLE / V<i>P<j>，i 是 DVFS 表下标；
// - 逐核通道按出现顺序对应 logical cpu 0..n-1（两台机器上都成立，启动时逐项校验）；
// - 簇通道名是该簇所有逐核通道名的最长公共前缀（最长前缀匹配）；
// - 「实际频率」簇通道与「请求」簇通道状态名完全相同、名字等长且只差一个字符；
// - pmgr 的 perf-domains 是 28 字节记录：byte0 = voltage-states 键号，offset 12 起 16 字节是域名，
//   域名与 IOReport 簇通道名一致；
// - voltage-states<k>-sram（缺失时退回 voltage-states<k>）是 (freq, mV) 的 u32 对，频率单位按量级判定。
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ioreport.h"

#define TD_MAXCPU 256
#define TD_MAXCL 32
#define TD_MAXPL 8
#define TD_MAXCC 16

typedef struct { char name[64]; int logical; int cpusperl2; long long l2, l1d, l1i; } TDPerfLevel;

typedef struct {
  uint32_t id; int ncores; int cpus[64];
  char compat[64]; uint32_t l2; int cls;
  char coreNames[64][32];
  char cpuName[32];      // 请求频率簇通道（最长公共前缀规则）
  char cpmName[32];      // 实际频率簇通道（等长差一字符 + 状态名相同）
  int nV;                // 逐核通道的 V 状态数
  int vsIndexPD;         // perf-domains 给出的表键号，-1 = 没有
  int vsIndexCount;      // 按状态数匹配得到的表键号，-1 = 没有 / -2 = 有歧义
  int vsIndex;           // 最终采用
  double tbl[64]; int ntbl; double maxMHz;
} TDCluster;

typedef struct { char compat[64]; int ncpu; int ncl; int clSize; uint32_t l2; double maxMHz; int plByCount, plByFreq, plByL2, perflevel; } TDClass;

typedef struct { int key; int sram; int n; double mhz[64]; int valid; const char* unit; } TDTable;

static int td_ncpu; static int td_cpuCluster[TD_MAXCPU];
static TDCluster td_cl[TD_MAXCL]; static int td_ncl;
static TDPerfLevel td_pl[TD_MAXPL]; static int td_npl;
static TDClass td_cc[TD_MAXCC]; static int td_ncc;
static TDTable td_tbl[128]; static int td_ntbl;
static char td_coreChan[TD_MAXCPU][32]; static int td_ncoreChan;
static char td_cxChan[64][32]; static int td_cxNV[64]; static int td_ncx;
static char td_cxStates[64][512];
typedef struct { char name[17]; int vs; } TDDomain;
static TDDomain td_pd[64]; static int td_npd = -1;

static void td_cs(CFStringRef s, char* b, int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
static long long td_sint(const char* n){ long long v=0; size_t s=sizeof v; if(sysctlbyname(n,&v,&s,NULL,0)) return -1; return s==4? (int)v : v; }

static int td_u32prop(io_registry_entry_t e, const char* k, uint32_t* out){
  CFStringRef key=CFStringCreateWithCString(NULL,k,kCFStringEncodingUTF8);
  CFTypeRef v=IORegistryEntryCreateCFProperty(e,key,NULL,0); CFRelease(key); if(!v) return 0; int ok=0;
  if(CFGetTypeID(v)==CFDataGetTypeID() && CFDataGetLength(v)>=4){ memcpy(out,CFDataGetBytePtr(v),4); ok=1; }
  else if(CFGetTypeID(v)==CFNumberGetTypeID()){ CFNumberGetValue(v,kCFNumberSInt32Type,out); ok=2; }
  CFRelease(v); return ok; }
static void td_firstString(io_registry_entry_t e, const char* k, char* b, int n){
  b[0]=0; CFStringRef key=CFStringCreateWithCString(NULL,k,kCFStringEncodingUTF8);
  CFTypeRef v=IORegistryEntryCreateCFProperty(e,key,NULL,0); CFRelease(key); if(!v) return;
  if(CFGetTypeID(v)==CFDataGetTypeID()){ int l=(int)CFDataGetLength(v); if(l>=n) l=n-1; memcpy(b,CFDataGetBytePtr(v),l); b[l]=0; }
  CFRelease(v); }

// 1) sysctl perflevel
static void td_readPerfLevels(void){
  td_npl=(int)td_sint("hw.nperflevels"); if(td_npl<1||td_npl>TD_MAXPL) td_npl=0;
  for(int i=0;i<td_npl;i++){ char k[64]; size_t s=64;
    snprintf(k,64,"hw.perflevel%d.name",i); s=sizeof td_pl[i].name; if(sysctlbyname(k,td_pl[i].name,&s,NULL,0)) strcpy(td_pl[i].name,"?");
    snprintf(k,64,"hw.perflevel%d.logicalcpu_max",i); td_pl[i].logical=(int)td_sint(k);
    snprintf(k,64,"hw.perflevel%d.cpusperl2",i); td_pl[i].cpusperl2=(int)td_sint(k);
    snprintf(k,64,"hw.perflevel%d.l2cachesize",i); td_pl[i].l2=td_sint(k);
    snprintf(k,64,"hw.perflevel%d.l1dcachesize",i); td_pl[i].l1d=td_sint(k);
    snprintf(k,64,"hw.perflevel%d.l1icachesize",i); td_pl[i].l1i=td_sint(k); }
}

// 2) IODeviceTree:/cpus → 簇与核类别（按 compatible 首串分组，不解释其含义）
static int td_readDT(void){
  io_registry_entry_t cpus=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/cpus"); if(!cpus) return -1;
  io_iterator_t it; IORegistryEntryGetChildIterator(cpus,kIODeviceTreePlane,&it); io_registry_entry_t c; td_ncpu=0;
  uint32_t lcid[TD_MAXCPU], cid[TD_MAXCPU], l2[TD_MAXCPU]; char comp[TD_MAXCPU][64]; int n=0;
  while((c=IOIteratorNext(it)) && n<TD_MAXCPU){
    uint32_t a=~0u,b=~0u,z=0,die=0; if(td_u32prop(c,"logical-cpu-id",&a) && td_u32prop(c,"cluster-id",&b)){
      // 簇键 = (die-id, cluster-id)：多 die 芯片上 cluster-id 是否全局唯一没有实测，保守起见带上 die-id
      td_u32prop(c,"die-id",&die); td_u32prop(c,"l2-cache-size",&z); lcid[n]=a; cid[n]=(die<<16)|(b&0xffff); l2[n]=z; td_firstString(c,"compatible",comp[n],64);
      // 核类别键 = compatible 首串 + cluster-type（两者都只当不透明字符串比较，不解释字母含义）
      char ct[16]; td_firstString(c,"cluster-type",ct,16); strncat(comp[n],"/",63-strlen(comp[n])); strncat(comp[n],ct,63-strlen(comp[n])); n++; }
    IOObjectRelease(c); }
  IOObjectRelease(it); IOObjectRelease(cpus);
  td_ncpu=n; td_ncl=0;
  for(int i=0;i<n;i++){ if(lcid[i]>=TD_MAXCPU) return -2; int k; for(k=0;k<td_ncl;k++) if(td_cl[k].id==cid[i]) break;
    if(k==td_ncl){ memset(&td_cl[k],0,sizeof td_cl[k]); td_cl[k].id=cid[i]; strcpy(td_cl[k].compat,comp[i]); td_cl[k].l2=l2[i]; td_cl[k].vsIndex=td_cl[k].vsIndexPD=td_cl[k].vsIndexCount=-1; td_ncl++; }
    td_cl[k].cpus[td_cl[k].ncores++]=(int)lcid[i]; td_cpuCluster[lcid[i]]=k; }
  // 簇按 cluster-id 排序，簇内按 cpu 号排序（便于阅读，算法不依赖）
  for(int a=0;a<td_ncl;a++) for(int b=a+1;b<td_ncl;b++) if(td_cl[b].id<td_cl[a].id){ TDCluster t=td_cl[a]; td_cl[a]=td_cl[b]; td_cl[b]=t; }
  for(int k=0;k<td_ncl;k++){ for(int a=0;a<td_cl[k].ncores;a++) for(int b=a+1;b<td_cl[k].ncores;b++) if(td_cl[k].cpus[b]<td_cl[k].cpus[a]){ int t=td_cl[k].cpus[a]; td_cl[k].cpus[a]=td_cl[k].cpus[b]; td_cl[k].cpus[b]=t; }
    for(int a=0;a<td_cl[k].ncores;a++) td_cpuCluster[td_cl[k].cpus[a]]=k; }
  // 核类别
  td_ncc=0;
  for(int k=0;k<td_ncl;k++){ int j; for(j=0;j<td_ncc;j++) if(!strcmp(td_cc[j].compat,td_cl[k].compat)) break;
    if(j==td_ncc){ memset(&td_cc[j],0,sizeof td_cc[j]); strcpy(td_cc[j].compat,td_cl[k].compat); td_cc[j].clSize=td_cl[k].ncores; td_cc[j].l2=td_cl[k].l2; td_cc[j].plByCount=td_cc[j].plByFreq=td_cc[j].plByL2=td_cc[j].perflevel=-1; td_ncc++; }
    td_cl[k].cls=j; td_cc[j].ncpu+=td_cl[k].ncores; td_cc[j].ncl++; if(td_cc[j].clSize!=td_cl[k].ncores) td_cc[j].clSize=-1; }
  return 0;
}

// 3) pmgr：perf-domains 与 voltage-states*
static io_registry_entry_t td_pmgr(void){
  io_iterator_t it; if(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &it)!=KERN_SUCCESS) return 0;
  io_registry_entry_t e=IOIteratorNext(it), x; while((x=IOIteratorNext(it))) IOObjectRelease(x); IOObjectRelease(it); return e; }

static void td_readPmgr(void){
  io_registry_entry_t pm=td_pmgr(); if(!pm) return;
  CFMutableDictionaryRef props=NULL; IORegistryEntryCreateCFProperties(pm,&props,NULL,0); IOObjectRelease(pm); if(!props) return;
  CFDataRef pd=CFDictionaryGetValue(props,CFSTR("perf-domains"));
  if(pd && CFGetTypeID(pd)==CFDataGetTypeID() && CFDataGetLength(pd)%28==0){
    const uint8_t* p=CFDataGetBytePtr(pd); td_npd=0;
    for(CFIndex o=0;o<CFDataGetLength(pd) && td_npd<64;o+=28){ td_pd[td_npd].vs=p[o]; memcpy(td_pd[td_npd].name,p+o+12,16); td_pd[td_npd].name[16]=0; td_npd++; } }
  CFIndex n=CFDictionaryGetCount(props); const void** ks=malloc(n*sizeof(void*)); const void** vs=malloc(n*sizeof(void*)); CFDictionaryGetKeysAndValues(props,ks,vs);
  td_ntbl=0;
  for(CFIndex i=0;i<n && td_ntbl<128;i++){ char k[128]; td_cs(ks[i],k,128); if(strncmp(k,"voltage-states",14)) continue;
    char* end; long key=strtol(k+14,&end,10); int sram=0; if(end==k+14) continue; if(*end){ if(!strcmp(end,"-sram")) sram=1; else continue; }
    if(CFGetTypeID(vs[i])!=CFDataGetTypeID()) continue; CFIndex len=CFDataGetLength(vs[i]); if(len%8||len==0||len/8>64) continue;
    const uint32_t* d=(const uint32_t*)CFDataGetBytePtr(vs[i]); TDTable* t=&td_tbl[td_ntbl++]; t->key=(int)key; t->sram=sram; t->n=(int)(len/8);
    uint32_t mx=0; int mono=1, pos=1; for(int j=0;j<t->n;j++){ uint32_t f=d[2*j]; if(f>mx) mx=f; if(j && f<d[2*(j-1)]) mono=0; if(!f) pos=0; }
    double div = mx>=100000000u? 1e6 : (mx>=100000u? 1e3 : 0); t->unit = div==1e6? "Hz" : (div==1e3? "kHz":"?");
    for(int j=0;j<t->n;j++) t->mhz[j]= div? d[2*j]/div : 0;
    double maxMHz = div? mx/div : 0;
    // CPU 表的合理性：单调不减、没有 0 档、最高档在 500–10000 MHz
    t->valid = div && mono && pos && maxMHz>=500 && maxMHz<=10000; }
  free(ks); free(vs); CFRelease(props);
}
static TDTable* td_findTable(int key){ TDTable* plain=NULL; for(int i=0;i<td_ntbl;i++) if(td_tbl[i].key==key){ if(td_tbl[i].sram) return &td_tbl[i]; plain=&td_tbl[i]; } return plain; }

// 4) IOReport 通道结构（只取一次样本，读通道名与状态名）
static int td_isV(const char* s){ return s[0]=='V' && s[1]>='0' && s[1]<='9'; }
static void td_readIOReportStructure(void){
  CFMutableDictionaryRef a=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Core Performance States"),0,0,0);
  CFMutableDictionaryRef b=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),CFSTR("CPU Complex Performance States"),0,0,0);
  if(!a||!b) return; IOReportMergeChannels(a,b,NULL);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,a,&subbed,0,NULL); if(!sub) return;
  CFDictionaryRef s=IOReportCreateSamples(sub,subbed,NULL); CFArrayRef arr=CFDictionaryGetValue(s,CFSTR("IOReportChannels"));
  td_ncoreChan=0; td_ncx=0; int coreNV[TD_MAXCPU];
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char sg[96], nm[32]; td_cs(IOReportChannelGetSubGroup(ch),sg,96); td_cs(IOReportChannelGetChannelName(ch),nm,32);
    int ns=IOReportStateGetCount(ch), nv=0; char states[512]={0};
    for(int k=0;k<ns;k++){ char st[32]; td_cs(IOReportStateGetNameForIndex(ch,k),st,32); if(td_isV(st)) nv++; strncat(states,st,sizeof states-strlen(states)-2); strcat(states,","); }
    if(!strcmp(sg,"CPU Core Performance States") && td_ncoreChan<TD_MAXCPU){ strcpy(td_coreChan[td_ncoreChan],nm); coreNV[td_ncoreChan]=nv; td_ncoreChan++; }
    else if(!strcmp(sg,"CPU Complex Performance States") && td_ncx<64){ strcpy(td_cxChan[td_ncx],nm); td_cxNV[td_ncx]=nv; strcpy(td_cxStates[td_ncx],states); td_ncx++; } }
  CFRelease(s);
  // 逐核通道 k ↔ logical cpu k；按簇收集
  for(int k=0;k<td_ncl;k++){ TDCluster* c=&td_cl[k]; c->nV=-1;
    for(int j=0;j<c->ncores;j++){ int cpu=c->cpus[j]; if(cpu<td_ncoreChan){ strcpy(c->coreNames[j],td_coreChan[cpu]); if(c->nV==-1) c->nV=coreNV[cpu]; else if(c->nV!=coreNV[cpu]) c->nV=-2; } }
    // 最长前缀：簇通道名是该簇所有逐核通道名的前缀，取最长者
    int best=-1; for(int x=0;x<td_ncx;x++){ size_t L=strlen(td_cxChan[x]); int all=1; for(int j=0;j<c->ncores;j++) if(strncmp(c->coreNames[j],td_cxChan[x],L)){ all=0; break; }
      if(all && (best<0 || L>strlen(td_cxChan[best]))) best=x; }
    if(best>=0){ strcpy(c->cpuName,td_cxChan[best]);
      // 其他簇的逐核通道名不能也以它为最长前缀（否则映射有歧义）——在 td_validate 里查
      for(int x=0;x<td_ncx;x++){ if(x==best) continue; if(strlen(td_cxChan[x])!=strlen(td_cxChan[best])) continue; if(strcmp(td_cxStates[x],td_cxStates[best])) continue;
        int diff=0; for(size_t q=0;q<strlen(td_cxChan[x]);q++) if(td_cxChan[x][q]!=td_cxChan[best][q]) diff++;
        int isCoreprefix=0; for(int y=0;y<td_ncoreChan;y++) if(!strncmp(td_coreChan[y],td_cxChan[x],strlen(td_cxChan[x]))) isCoreprefix=1;
        if(diff==1 && !isCoreprefix){ strcpy(c->cpmName,td_cxChan[x]); break; } } }
  }
}

// 5) 簇 ↔ DVFS 表
static void td_matchTables(void){
  for(int k=0;k<td_ncl;k++){ TDCluster* c=&td_cl[k];
    if(td_npd>0 && c->cpuName[0]) for(int i=0;i<td_npd;i++) if(!strcmp(td_pd[i].name,c->cpuName)){ TDTable* t=td_findTable(td_pd[i].vs); if(t && t->valid && t->n==c->nV) c->vsIndexPD=td_pd[i].vs; else c->vsIndexPD=-3; }
    // 按状态数：候选的合法 CPU 表里 n == nV；内容完全相同的视为同一张
    int found=-1; for(int i=0;i<td_ntbl;i++){ TDTable* t=&td_tbl[i]; if(!t->valid || t->n!=c->nV) continue; if(!t->sram && td_findTable(t->key)!=t) continue;
      if(found<0) found=t->key; else { TDTable* f=td_findTable(found); if(memcmp(f->mhz,t->mhz,sizeof(double)*t->n)) found=-2; } }
    c->vsIndexCount=found;
    c->vsIndex = c->vsIndexPD>=0? c->vsIndexPD : (c->vsIndexCount>=0? c->vsIndexCount : -1);
    if(c->vsIndex>=0){ TDTable* t=td_findTable(c->vsIndex); c->ntbl=t->n; memcpy(c->tbl,t->mhz,sizeof(double)*t->n); c->maxMHz=t->mhz[t->n-1]; } }
  for(int j=0;j<td_ncc;j++){ td_cc[j].maxMHz=0; for(int k=0;k<td_ncl;k++) if(td_cl[k].cls==j && td_cl[k].maxMHz>td_cc[j].maxMHz) td_cc[j].maxMHz=td_cl[k].maxMHz; }
}

// 6) 核类别 → perflevel：三种独立依据，最后比较是否一致
static void td_assignPerfLevels(void){
  // a) 数量：类别总核数 == logicalcpu_max 且簇大小 == cpusperl2，且唯一
  for(int j=0;j<td_ncc;j++){ int cand=-1, nc=0; for(int p=0;p<td_npl;p++) if(td_pl[p].logical==td_cc[j].ncpu && td_pl[p].cpusperl2==td_cc[j].clSize){ cand=p; nc++; } td_cc[j].plByCount = nc==1? cand : -1; }
  // b) DVFS 最高频率降序 ↔ perflevel 0..n-1（perflevel0 是最快档）
  // c) DT l2-cache-size 降序 ↔ perflevel 0..n-1
  if(td_ncc==td_npl){
    for(int j=0;j<td_ncc;j++){ int rf=0, rl=0, tieF=0, tieL=0; for(int i=0;i<td_ncc;i++){ if(i==j) continue; if(td_cc[i].maxMHz>td_cc[j].maxMHz) rf++; if(td_cc[i].maxMHz==td_cc[j].maxMHz) tieF=1; if(td_cc[i].l2>td_cc[j].l2) rl++; if(td_cc[i].l2==td_cc[j].l2) tieL=1; }
      td_cc[j].plByFreq = (tieF||td_cc[j].maxMHz<=0)? -1 : rf; td_cc[j].plByL2 = tieL? -1 : rl; } }
  for(int j=0;j<td_ncc;j++){ td_cc[j].perflevel = td_cc[j].plByCount>=0? td_cc[j].plByCount : (td_cc[j].plByFreq>=0? td_cc[j].plByFreq : td_cc[j].plByL2); }
}

static int td_clusterPerfLevel(int k){ return td_cc[td_cl[k].cls].perflevel; }

static void td_discover(void){ td_readPerfLevels(); td_readDT(); td_readPmgr(); td_readIOReportStructure(); td_matchTables(); td_assignPerfLevels(); }

static void td_print(FILE* f){
  fprintf(f,"perflevels=%d:", td_npl); for(int p=0;p<td_npl;p++) fprintf(f," [%d %s logical=%d cpusperl2=%d l2=%lldMB l1d=%lldKB]", p, td_pl[p].name, td_pl[p].logical, td_pl[p].cpusperl2, td_pl[p].l2>>20, td_pl[p].l1d>>10); fprintf(f,"\n");
  fprintf(f,"DT cpus=%d clusters=%d classes=%d | IOReport core channels=%d complex channels=%d | perf-domains=%d tables=%d\n", td_ncpu, td_ncl, td_ncc, td_ncoreChan, td_ncx, td_npd, td_ntbl);
  for(int j=0;j<td_ncc;j++) fprintf(f,"class %d compat=%s cpus=%d clusters=%d clSize=%d DT-l2=%uMB maxMHz=%.0f -> perflevel byCount=%d byFreq=%d byL2=%d => %d (%s)\n", j, td_cc[j].compat, td_cc[j].ncpu, td_cc[j].ncl, td_cc[j].clSize, td_cc[j].l2>>20, td_cc[j].maxMHz, td_cc[j].plByCount, td_cc[j].plByFreq, td_cc[j].plByL2, td_cc[j].perflevel, td_cc[j].perflevel>=0 && td_cc[j].perflevel<td_npl? td_pl[td_cc[j].perflevel].name:"?");
  for(int k=0;k<td_ncl;k++){ TDCluster* c=&td_cl[k]; fprintf(f,"cluster id=%u cpus=%d..%d (n=%d) class=%d perflevel=%d | coreChan=%s..%s nV=%d | complex req=%s actual=%s | table: perf-domains=%d byCount=%d => voltage-states%d n=%d %.0f..%.0f MHz\n",
      c->id, c->cpus[0], c->cpus[c->ncores-1], c->ncores, c->cls, td_clusterPerfLevel(k), c->coreNames[0], c->coreNames[c->ncores-1], c->nV, c->cpuName[0]?c->cpuName:"-", c->cpmName[0]?c->cpmName:"-", c->vsIndexPD, c->vsIndexCount, c->vsIndex, c->ntbl, c->ntbl?c->tbl[0]:0, c->ntbl?c->tbl[c->ntbl-1]:0); }
}
