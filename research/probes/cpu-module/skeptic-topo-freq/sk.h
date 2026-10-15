// skeptic-topo-freq 探针共用头：独立于 topo-freq/topo_discover.h 重写（不复用其发现代码），
// 只保留同一组私有 IOReport 符号声明（签名来自公开社区资料，与 research/probes/cpu/bridge_ioreport.h 一致）。
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
uint64_t IOReportChannelGetChannelID(CFDictionaryRef);
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);

#define SK_MAXCPU 128
static inline void sk_cs(CFStringRef s, char* b, int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
static inline long long sk_sysint(const char* n){ long long v=0; size_t s=sizeof v; if(sysctlbyname(n,&v,&s,NULL,0)) return -1; return s==4? (long long)(int)v : v; }
static inline double sk_now_s(void){ return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e9; }
static inline double sk_thread_cpu_us(void){ return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)/1000.0; }
// mach 时间单位 → 纳秒（运行时读取，不写死 125/3）
static inline double sk_mach_to_ns(void){ static double f=0; if(!f){ mach_timebase_info_data_t tb; mach_timebase_info(&tb); f=(double)tb.numer/tb.denom; } return f; }

// IORegistry 属性读取：u32（data 或 number），字符串（data 首串）
static inline int sk_u32(io_registry_entry_t e, const char* k, uint32_t* out){
  CFStringRef key=CFStringCreateWithCString(NULL,k,kCFStringEncodingUTF8); CFTypeRef v=IORegistryEntryCreateCFProperty(e,key,NULL,0); CFRelease(key);
  if(!v) return 0; int ok=0;
  if(CFGetTypeID(v)==CFDataGetTypeID() && CFDataGetLength(v)>=4){ memcpy(out,CFDataGetBytePtr(v),4); ok=1; }
  else if(CFGetTypeID(v)==CFNumberGetTypeID()){ CFNumberGetValue(v,kCFNumberSInt32Type,out); ok=1; }
  CFRelease(v); return ok; }
static inline int sk_str(io_registry_entry_t e, const char* k, char* b, int n){
  b[0]=0; CFStringRef key=CFStringCreateWithCString(NULL,k,kCFStringEncodingUTF8); CFTypeRef v=IORegistryEntryCreateCFProperty(e,key,NULL,0); CFRelease(key);
  if(!v) return 0; if(CFGetTypeID(v)==CFDataGetTypeID()){ int l=(int)CFDataGetLength(v); if(l>=n) l=n-1; memcpy(b,CFDataGetBytePtr(v),l); b[l]=0; }
  else if(CFGetTypeID(v)==CFStringGetTypeID()) sk_cs(v,b,n);
  CFRelease(v); return 1; }

// ---------- 独立的拓扑读取：DT /cpus ----------
typedef struct { int n; int lcid[SK_MAXCPU]; uint32_t cid[SK_MAXCPU], die[SK_MAXCPU], l2[SK_MAXCPU]; char type[SK_MAXCPU][8]; char compat[SK_MAXCPU][40]; uint64_t reg[SK_MAXCPU]; } SKDT;
static inline int sk_read_dt(SKDT* d){
  memset(d,0,sizeof *d);
  io_registry_entry_t cpus=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/cpus"); if(!cpus) return -1;
  io_iterator_t it; if(IORegistryEntryGetChildIterator(cpus,kIODeviceTreePlane,&it)){ IOObjectRelease(cpus); return -1; }
  io_registry_entry_t c;
  while((c=IOIteratorNext(it))){
    uint32_t l=~0u; if(sk_u32(c,"logical-cpu-id",&l) && d->n<SK_MAXCPU){ int i=d->n++; d->lcid[i]=(int)l;
      d->cid[i]=~0u; sk_u32(c,"cluster-id",&d->cid[i]); d->die[i]=0; sk_u32(c,"die-id",&d->die[i]); sk_u32(c,"l2-cache-size",&d->l2[i]);
      sk_str(c,"cluster-type",d->type[i],8); sk_str(c,"compatible",d->compat[i],40);
      CFTypeRef r=IORegistryEntryCreateCFProperty(c,CFSTR("reg"),NULL,0); if(r){ if(CFGetTypeID(r)==CFDataGetTypeID()){ CFIndex L=CFDataGetLength(r); if(L>8) L=8; memcpy(&d->reg[i],CFDataGetBytePtr(r),L);} CFRelease(r);} }
    IOObjectRelease(c); }
  IOObjectRelease(it); IOObjectRelease(cpus); return d->n; }

// ---------- 每核 tick ----------
static inline int sk_ticks(uint64_t out[][4]){
  natural_t n; processor_info_array_t info; mach_msg_type_number_t cnt;
  if(host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt)) return 0;
  for(unsigned i=0;i<n && i<SK_MAXCPU;i++) for(int s=0;s<4;s++) out[i][s]=(uint32_t)info[i*CPU_STATE_MAX+s];
  vm_deallocate(mach_task_self(), (vm_address_t)info, cnt*sizeof(int)); return (int)n; }
