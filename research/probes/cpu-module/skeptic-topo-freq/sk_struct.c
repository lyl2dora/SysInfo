// 复核探针 1：结构 dump（只读、无负载）。独立核对 topo-freq 的以下结论：
//  - DT logical-cpu-id / cluster-id / die-id 与 host_processor_info、hw.logicalcpu_max 的核数一致；
//  - pmgr perf-domains 的 28 字节记录格式（byte0=表键号、offset12 起 16 字节=域名），整条 hex 打出来看其余字节；
//  - voltage-states<k> 与 -sram 变体的频率列是否一致、单位（Hz/kHz）；
//  - IOReport CPU Stats 各子组的通道名、ChannelID、状态名（看 ChannelID 是否能替代「出现顺序」来映射核号）；
//  - mach_timebase_info（topo-freq 的探针把 125/3 写死了）。
#include "sk.h"
#include <mach/processor_info.h>

static io_registry_entry_t pmgr(void){ io_iterator_t it; if(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &it)) return 0;
  io_registry_entry_t e=IOIteratorNext(it), x; int extra=0; while((x=IOIteratorNext(it))){ extra++; IOObjectRelease(x); } IOObjectRelease(it);
  if(extra) printf("NOTE: %d extra services named pmgr\n", extra); return e; }

typedef struct { long key; int sram; int n; uint32_t f[64]; uint32_t mv[64]; } T;
static T tb[256]; static int ntb;

int main(void){
  mach_timebase_info_data_t tbi; mach_timebase_info(&tbi); char model[64]={0}; size_t ms=sizeof model; sysctlbyname("hw.model",model,&ms,NULL,0);
  char build[32]={0}; size_t bs=sizeof build; sysctlbyname("kern.osversion",build,&bs,NULL,0);
  printf("model=%s build=%s timebase=%u/%u  hw.logicalcpu_max=%lld hw.activecpu=%lld nperflevels=%lld\n", model, build, tbi.numer, tbi.denom, sk_sysint("hw.logicalcpu_max"), sk_sysint("hw.activecpu"), sk_sysint("hw.nperflevels"));
  for(int p=0;p<sk_sysint("hw.nperflevels");p++){ char k[64], nm[32]={0}; size_t s=sizeof nm; snprintf(k,64,"hw.perflevel%d.name",p); sysctlbyname(k,nm,&s,NULL,0);
    char k2[64], k3[64], k4[64]; snprintf(k2,64,"hw.perflevel%d.logicalcpu_max",p); snprintf(k3,64,"hw.perflevel%d.cpusperl2",p); snprintf(k4,64,"hw.perflevel%d.l2cachesize",p);
    printf("  perflevel%d name=%s logical=%lld cpusperl2=%lld l2=%lldMB\n", p, nm, sk_sysint(k2), sk_sysint(k3), sk_sysint(k4)>>20); }

  SKDT d; int n=sk_read_dt(&d); printf("\nDT /cpus: %d nodes with logical-cpu-id\n", n);
  for(int i=0;i<n;i++) printf("  node#%-2d lcid=%-2d die=%u cluster=%u type=%-2s compat=%-18s l2=%uMB reg=0x%llx\n", i, d.lcid[i], d.die[i], d.cid[i], d.type[i], d.compat[i], d.l2[i]>>20, (unsigned long long)d.reg[i]);

  natural_t np; processor_info_array_t info; mach_msg_type_number_t cnt;
  if(!host_processor_info(mach_host_self(), PROCESSOR_BASIC_INFO, &np, &info, &cnt)){
    printf("\nhost_processor_info(BASIC) n=%u:", np);
    for(unsigned i=0;i<np;i++){ processor_basic_info_t b=(processor_basic_info_t)(info+i*PROCESSOR_BASIC_INFO_COUNT); printf(" [%u slot=%d run=%d master=%d]", i, b->slot_num, b->running, b->is_master); }
    printf("\n"); vm_deallocate(mach_task_self(),(vm_address_t)info,cnt*sizeof(int)); }

  io_registry_entry_t pm=pmgr(); if(!pm){ printf("no pmgr\n"); return 0; }
  io_string_t path; IORegistryEntryGetPath(pm,kIODeviceTreePlane,path); printf("\npmgr DT path: %s\n", path);
  CFMutableDictionaryRef props=NULL; IORegistryEntryCreateCFProperties(pm,&props,NULL,0);
  CFDataRef pd=CFDictionaryGetValue(props,CFSTR("perf-domains"));
  if(pd){ CFIndex L=CFDataGetLength(pd); const uint8_t* p=CFDataGetBytePtr(pd); printf("perf-domains: %ld bytes (%%28=%ld)\n", (long)L, (long)(L%28));
    for(CFIndex o=0;o+28<=L;o+=28){ printf("  rec%-2ld:", (long)(o/28)); for(int b=0;b<12;b++) printf(" %02x", p[o+b]); char nm[17]={0}; memcpy(nm,p+o+12,16); printf(" | name=\"%s\"\n", nm); } }
  else printf("perf-domains: ABSENT\n");
  CFDataRef ac=CFDictionaryGetValue(props,CFSTR("acc-clusters"));
  if(ac){ CFIndex L=CFDataGetLength(ac); const uint8_t* p=CFDataGetBytePtr(ac); printf("acc-clusters: %ld bytes:", (long)L); for(CFIndex b=0;b<L && b<128;b++) printf("%s%02x", b%4?"":" ", p[b]); printf("\n"); }
  else printf("acc-clusters: ABSENT\n");
  CFIndex nk=CFDictionaryGetCount(props); const void** ks=malloc(nk*sizeof(void*)); const void** vs=malloc(nk*sizeof(void*)); CFDictionaryGetKeysAndValues(props,ks,vs);
  for(CFIndex i=0;i<nk;i++){ char k[128]; sk_cs(ks[i],k,128); if(strncmp(k,"voltage-states",14)) continue; char* e; long key=strtol(k+14,&e,10); if(e==k+14) continue;
    int sram= !strcmp(e,"-sram"); if(*e && !sram){ printf("  (other key %s)\n", k); continue; }
    if(CFGetTypeID(vs[i])!=CFDataGetTypeID()) continue; CFIndex L=CFDataGetLength(vs[i]); if(L%8 || L/8>64){ printf("  %s: odd length %ld\n", k, (long)L); continue; }
    T* t=&tb[ntb++]; t->key=key; t->sram=sram; t->n=(int)(L/8); const uint32_t* q=(const uint32_t*)CFDataGetBytePtr(vs[i]); for(int j=0;j<t->n;j++){ t->f[j]=q[2*j]; t->mv[j]=q[2*j+1]; } }
  // 排序输出
  for(int a=0;a<ntb;a++) for(int b=a+1;b<ntb;b++) if(tb[b].key<tb[a].key || (tb[b].key==tb[a].key && tb[b].sram<tb[a].sram)){ T x=tb[a]; tb[a]=tb[b]; tb[b]=x; }
  printf("voltage-states tables (%d):\n", ntb);
  for(int a=0;a<ntb;a++){ T* t=&tb[a]; uint32_t mx=0; for(int j=0;j<t->n;j++) if(t->f[j]>mx) mx=t->f[j];
    int sameAsPlain=-1; if(t->sram) for(int b=0;b<ntb;b++) if(tb[b].key==t->key && !tb[b].sram){ sameAsPlain = tb[b].n==t->n; for(int j=0;j<t->n && sameAsPlain;j++) if(tb[b].f[j]!=t->f[j]) sameAsPlain=0; }
    printf("  vs%-3ld%-5s n=%-2d f[0]=%u f[max]=%u  mV %u..%u%s\n", t->key, t->sram?"-sram":"", t->n, t->f[0], mx, t->mv[0], t->mv[t->n-1], sameAsPlain==1?"  freq column == plain":(sameAsPlain==0?"  freq column DIFFERS from plain":""));
  }
  free(ks); free(vs); CFRelease(props); IOObjectRelease(pm);

  // IOReport CPU Stats 全组
  CFMutableDictionaryRef g=IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),NULL,0,0,0);
  if(!g){ printf("no CPU Stats\n"); return 0; }
  CFMutableDictionaryRef sb=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,g,&sb,0,NULL);
  CFDictionaryRef s=IOReportCreateSamples(sub,sb,NULL); CFArrayRef arr=CFDictionaryGetValue(s,CFSTR("IOReportChannels"));
  printf("\nIOReport CPU Stats: %ld channels\n", (long)CFArrayGetCount(arr));
  char lastsg[96]=""; int cntsg=0;
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char sg[96], nm[48], dr[96]; sk_cs(IOReportChannelGetSubGroup(ch),sg,96); sk_cs(IOReportChannelGetChannelName(ch),nm,48); sk_cs(IOReportChannelGetDriverName(ch),dr,96);
    if(strcmp(sg,lastsg)){ printf(" -- subgroup \"%s\" (driver %s)\n", sg, dr); strcpy(lastsg,sg); cntsg=0; }
    cntsg++; if(!strcmp(sg,"CPU Complex Voltage State Time") && cntsg>3) continue;
    int ns=IOReportStateGetCount(ch); printf("   #%-3ld %-12s id=0x%016llx states=%d:", (long)i, nm, (unsigned long long)IOReportChannelGetChannelID(ch), ns);
    for(int k=0;k<ns;k++){ if(k>=4 && k<ns-2){ if(k==4) printf(" ..."); continue; } char st[32]; sk_cs(IOReportStateGetNameForIndex(ch,k),st,32); printf(" %s", st); } printf("\n"); }
  return 0; }
