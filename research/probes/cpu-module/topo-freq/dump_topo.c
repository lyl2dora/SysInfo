// 探针：两台机器上的拓扑与频率相关原始数据一次性导出（只读）。
// 1) sysctl hw.perflevelN.*；2) IODeviceTree:/cpus 子节点的逐核属性；3) pmgr voltage-states* 表概况；
// 4) IOReport "CPU Stats" 组全部通道（子组、名称、状态数、状态名、ChannelID/DriverID/DriverName）。
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <string.h>
#include "ioreport.h"

static void cs(CFStringRef s, char* b, int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
static long long sint(const char* n){ long long v=0; size_t s=sizeof v; if(sysctlbyname(n,&v,&s,NULL,0)) return -1; return s==4? (int)v : v; }
static void sstr(const char* n, char* b, size_t bl){ b[0]=0; size_t s=bl; if(sysctlbyname(n,b,&s,NULL,0)) strcpy(b,"(nil)"); }
static int u32prop(io_registry_entry_t e, const char* k, uint32_t* out){
  CFStringRef key=CFStringCreateWithCString(NULL,k,kCFStringEncodingUTF8);
  CFTypeRef v=IORegistryEntryCreateCFProperty(e,key,NULL,0); CFRelease(key); if(!v) return 0; int ok=0;
  if(CFGetTypeID(v)==CFDataGetTypeID() && CFDataGetLength(v)>=4){ memcpy(out,CFDataGetBytePtr(v),4); ok=1; }
  else if(CFGetTypeID(v)==CFNumberGetTypeID()){ CFNumberGetValue(v,kCFNumberSInt32Type,out); ok=2; }
  CFRelease(v); return ok; }
static void strprop(io_registry_entry_t e, const char* k, char* b, int n){
  b[0]=0; CFStringRef key=CFStringCreateWithCString(NULL,k,kCFStringEncodingUTF8);
  CFTypeRef v=IORegistryEntryCreateCFProperty(e,key,NULL,0); CFRelease(key); if(!v){ strcpy(b,"-"); return; }
  if(CFGetTypeID(v)==CFDataGetTypeID()){ int l=(int)CFDataGetLength(v); if(l>=n) l=n-1; memcpy(b,CFDataGetBytePtr(v),l); b[l]=0; for(int i=0;i<l;i++) if(!b[i]) b[i]=i==l-1?0:'|'; }
  else if(CFGetTypeID(v)==CFStringGetTypeID()) cs(v,b,n);
  CFRelease(v); }

int main(void){
  char b[256];
  sstr("hw.model",b,sizeof b); printf("== sysctl ==\nhw.model=%s ncpu=%lld nperflevels=%lld\n", b, sint("hw.ncpu"), sint("hw.nperflevels"));
  int nl=(int)sint("hw.nperflevels");
  for(int i=0;i<nl;i++){ char k[64], nm[64]; snprintf(k,64,"hw.perflevel%d.name",i); sstr(k,nm,64);
    #define F(x) (snprintf(k,64,"hw.perflevel%d." x,i), sint(k))
    printf("perflevel%d name=%s logical=%lld physical=%lld cpusperl2=%lld l2=%lld l1d=%lld l1i=%lld\n", i, nm, F("logicalcpu"), F("physicalcpu"), F("cpusperl2"), F("l2cachesize"), F("l1dcachesize"), F("l1icachesize")); }

  printf("\n== IODeviceTree:/cpus children ==\n");
  io_registry_entry_t cpus=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/cpus");
  printf("cpus node=%u\n", cpus);
  uint32_t v; 
  const char* nk[]={"max_cpus","cpu-cluster-count","e-core-count","p-core-count","m-core-count","s-core-count"};
  for(int i=0;i<6;i++){ if(u32prop(cpus,nk[i],&v)) printf("  %s=%u\n",nk[i],v); else printf("  %s=ABSENT\n",nk[i]); }
  io_iterator_t it; IORegistryEntryGetChildIterator(cpus,kIODeviceTreePlane,&it); io_registry_entry_t c;
  while((c=IOIteratorNext(it))){
    char name[64]; IORegistryEntryGetName(c,name);
    uint32_t lcid=~0u, cid=~0u, lclid=~0u, did=~0u, dcid=~0u, ccid=~0u, l2=0, l2id=~0u;
    int f1=u32prop(c,"logical-cpu-id",&lcid); u32prop(c,"cluster-id",&cid); int f2=u32prop(c,"logical-cluster-id",&lclid); u32prop(c,"die-id",&did); u32prop(c,"die-cluster-id",&dcid); u32prop(c,"cluster-core-id",&ccid); u32prop(c,"l2-cache-size",&l2); u32prop(c,"l2-cache-id",&l2id);
    char ct[16], comp[64], st[32]; strprop(c,"cluster-type",ct,16); strprop(c,"compatible",comp,64); strprop(c,"state",st,32);
    printf("%-6s logical-cpu-id=%u(%s) cluster-id=%u logical-cluster-id=%u(%s) die-id=%u die-cluster-id=%u cluster-core-id=%u l2-cache-id=%u l2-cache-size=%u(%.1fMB) cluster-type=%s compatible=%s state=%s\n",
      name, lcid, f1==2?"num":"data", cid, lclid, f2==2?"num":"data", did, dcid, ccid, l2id, l2, l2/1048576.0, ct, comp, st);
    IOObjectRelease(c); }
  IOObjectRelease(it); IOObjectRelease(cpus);

  printf("\n== pmgr voltage-states* ==\n");
  io_registry_entry_t pm=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/arm-io/pmgr");
  printf("pmgr node=%u\n", pm);
  CFMutableDictionaryRef props=NULL; IORegistryEntryCreateCFProperties(pm,&props,NULL,0);
  if(props){ CFIndex n=CFDictionaryGetCount(props); const void** ks=malloc(n*sizeof(void*)); const void** vs=malloc(n*sizeof(void*)); CFDictionaryGetKeysAndValues(props,ks,vs);
    // 按键名排序输出
    for(int pass=0;pass<2;pass++) for(int num=0;num<100;num++) for(CFIndex i=0;i<n;i++){ char k[128]; cs(ks[i],k,128); if(strncmp(k,"voltage-states",14)) continue;
      int kn=atoi(k+14); if(kn!=num) continue; int sram=strstr(k,"-sram")!=NULL; if(sram!=pass) continue;
      if(CFGetTypeID(vs[i])!=CFDataGetTypeID()) continue; const uint32_t* d=(const uint32_t*)CFDataGetBytePtr(vs[i]); int cnt=(int)CFDataGetLength(vs[i])/8;
      printf("%-22s n=%2d freq[0]=%u freq[last]=%u volt[0]=%u volt[last]=%u  freqs:", k, cnt, d[0], d[2*(cnt-1)], d[1], d[2*cnt-1]);
      for(int j=0;j<cnt;j++) printf(" %u", d[2*j]); printf("\n"); }
    CFRelease(props); }
  IOObjectRelease(pm);

  printf("\n== IOReport group 'CPU Stats' channels ==\n");
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),NULL,0,0,0);
  // 状态名只在样本里有：先订阅、取一次样本，再从样本里读通道
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  CFDictionaryRef smp=sub? IOReportCreateSamples(sub,subbed,NULL): NULL;
  CFArrayRef arr=CFDictionaryGetValue(smp? smp: ch,CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef x=CFArrayGetValueAtIndex(arr,i); char sg[96],nm[64],dn[128];
    cs(IOReportChannelGetSubGroup(x),sg,96); cs(IOReportChannelGetChannelName(x),nm,64); cs(IOReportChannelGetDriverName(x),dn,128);
    if(strstr(sg,"Voltage State Time")){ static int vst=0; if(vst++<4) printf("[%s] %s fmt=%d chID=0x%llx (simple)\n", sg, nm, IOReportChannelGetFormat(x), IOReportChannelGetChannelID(x)); continue; }
    int ns=IOReportStateGetCount(x); printf("[%s] %-12s fmt=%d chID=0x%llx drvID=0x%llx drv=%s states=%d:", sg, nm, IOReportChannelGetFormat(x), IOReportChannelGetChannelID(x), IOReportChannelGetDriverID(x), dn, ns);
    for(int k=0;k<ns;k++){ char s2[32]; cs(IOReportStateGetNameForIndex(x,k),s2,32); printf(" %s",s2); } printf("\n"); }
  if(CFArrayGetCount(arr)>0){ printf("\n-- first channel dict --\n"); CFShow(CFArrayGetValueAtIndex(arr,0)); }
  return 0;
}
