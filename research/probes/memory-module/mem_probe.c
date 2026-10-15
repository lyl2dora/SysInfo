// mem_probe.c - 内存模块边界复核（2026-10-16）：
// (1) sysctl 页面队列按活动监视器公式得出 App / 联动 / 压缩 / 已用 / 缓存，与 host_statistics64 对照；
// (2) 压力：kern.memorystatus_vm_pressure_level 与 memorystatus_level；
// (3) IOReport PMP 组里 "DCS BW" 子组的通道与状态名（只读，不施加负载）；
// (4) 进程 footprint：本 uid 全扫耗时。
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

static uint64_t sc(const char *n){ uint64_t v=0; size_t s=sizeof(v); if(sysctlbyname(n,&v,&s,NULL,0)!=0) return (uint64_t)-1; if(s==4) v&=0xffffffffull; return v; }
static double gib(uint64_t pages, uint64_t ps){ return (double)pages*ps/1073741824.0; }

typedef CFDictionaryRef (*CopyCh)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*Iter)(CFDictionaryRef, int (^)(CFDictionaryRef));
typedef CFStringRef (*GetStr)(CFDictionaryRef);
typedef int32_t (*StCount)(CFDictionaryRef);
typedef CFStringRef (*StName)(CFDictionaryRef, int32_t);

int main(void){
  uint64_t ps = sc("hw.pagesize"), mem = sc("hw.memsize"), usable = sc("hw.memsize_usable");
  uint64_t fr=sc("vm.page_free_count"), sp=sc("vm.page_speculative_count"), in=sc("vm.page_pageable_internal_count"),
           ex=sc("vm.page_pageable_external_count"), pu=sc("vm.page_purgeable_count"), wi=sc("vm.page_wired_count");
  vm_statistics64_data_t v; mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
  kern_return_t kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&v, &c);
  printf("model page=%llu memsize=%.2f GiB usable=%.2f GiB | host_statistics64 kr=%d count=%u (rev6=%u)\n", ps, mem/1073741824.0, usable/1073741824.0, kr, c, (unsigned)HOST_VM_INFO64_COUNT);
  double app=gib(in-pu,ps), wired=gib(wi,ps), comp=gib(v.compressor_page_count,ps);
  printf("sysctl: app=%.3f wired=%.3f compressed(hs64)=%.3f used=%.3f cached(ext+purg)=%.3f free(free+spec)=%.3f\n", app, wired, comp, app+wired+comp, gib(ex+pu,ps), gib(fr+sp,ps));
  printf("hs64:   app=%.3f wired=%.3f used=%.3f cached=%.3f free=%.3f\n", gib(v.internal_page_count-v.purgeable_count,ps), gib(v.wire_count,ps),
    gib(v.internal_page_count-v.purgeable_count+v.wire_count+v.compressor_page_count,ps), gib(v.external_page_count+v.purgeable_count,ps), gib(v.free_count+v.speculative_count,ps));
  printf("queue sum (free+spec+int+ext+wired+comp)=%.3f GiB vs usable %.3f\n", gib(fr+sp+in+ex+wi+v.compressor_page_count,ps), usable/1073741824.0);
  printf("compressor: occupied=%llu pages, holds %llu uncompressed pages, ratio %.2f; swapins=%llu swapouts=%llu pageins=%llu pageouts=%llu compressions=%llu decompressions=%llu\n",
    (unsigned long long)v.compressor_page_count,(unsigned long long)v.total_uncompressed_pages_in_compressor, v.compressor_page_count? (double)v.total_uncompressed_pages_in_compressor/v.compressor_page_count:0,
    (unsigned long long)v.swapins,(unsigned long long)v.swapouts,(unsigned long long)v.pageins,(unsigned long long)v.pageouts,(unsigned long long)v.compressions,(unsigned long long)v.decompressions);
  printf("pressure level=%llu memorystatus_level=%llu%%\n", sc("kern.memorystatus_vm_pressure_level"), sc("kern.memorystatus_level"));
  struct xsw_usage sw; size_t ss=sizeof(sw); sysctlbyname("vm.swapusage",&sw,&ss,NULL,0);
  printf("swap total=%llu used=%llu encrypted=%d\n",(unsigned long long)sw.xsu_total,(unsigned long long)sw.xsu_used,sw.xsu_encrypted);
  printf("ecc corrected=%llu uncorrected=%llu mte.tagged=%lld\n", sc("vm.vm_ecc_corrected_count"), sc("vm.vm_ecc_uncorrected_count"), (long long)sc("vm.mte.tagged"));

  // 进程 footprint 全扫
  int n = proc_listallpids(NULL,0); pid_t pids[8192]; n = proc_listallpids(pids,sizeof(pids)); int ok=0;
  uint64_t t0=mach_absolute_time(); uint64_t sum=0;
  for(int i=0;i<n;i++){ struct rusage_info_v6 r; if(proc_pid_rusage(pids[i],RUSAGE_INFO_V6,(rusage_info_t*)&r)==0){ ok++; sum+=r.ri_phys_footprint; } }
  uint64_t t1=mach_absolute_time(); mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  printf("proc_pid_rusage footprint scan: %d/%d readable, %.2f ms, sum=%.2f GiB\n", ok, n, (t1-t0)*tb.numer/tb.denom/1e6, sum/1073741824.0);

  // IOReport DCS BW
  void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
  CopyCh copy = h? (CopyCh)dlsym(h,"IOReportCopyChannelsInGroup"):NULL; Iter iter = h? (Iter)dlsym(h,"IOReportIterate"):NULL;
  GetStr name = h?(GetStr)dlsym(h,"IOReportChannelGetChannelName"):NULL; GetStr grp = h?(GetStr)dlsym(h,"IOReportChannelGetGroup"):NULL;
  StCount cnt = h?(StCount)dlsym(h,"IOReportStateGetCount"):NULL; StName sn=h?(StName)dlsym(h,"IOReportStateGetNameForIndex"):NULL;
  const char *groups[] = {"PMP0","PMP"};
  for(int g=0; g<2 && copy; g++){
    CFStringRef gs = CFStringCreateWithCString(NULL,groups[g],kCFStringEncodingUTF8);
    uint64_t a=mach_absolute_time(); CFDictionaryRef d = copy(gs, CFSTR("DCS BW"),0,0,0); uint64_t b=mach_absolute_time();
    __block int count=0;
    printf("IOReport group %s / DCS BW: %s (%.1f ms)\n", groups[g], d? "present":"absent", (b-a)*tb.numer/tb.denom/1e6);
    if(d){ iter(d, ^int(CFDictionaryRef ch){ char nm[64]; CFStringGetCString(name(ch),nm,64,kCFStringEncodingUTF8); count++;
        if(count<=12) printf("   ch %s states=%d first=%s\n", nm, cnt(ch), cnt(ch)>0? CFStringGetCStringPtr(sn(ch,0),kCFStringEncodingUTF8)?:"?" : "-"); return 0; });
      printf("   total channels=%d\n", count); CFRelease(d); }
    CFRelease(gs);
  }
  return 0;
}
