// ratelimit_probe.c - is host_statistics64(HOST_VM_INFO64) rate-limited/cached for a non-platform binary?
// Compare change frequency of host_statistics64 counters with sysctl vm.page_free_count / vm.pages_grabbed (not rate-limited).
#include <stdio.h>
#include <unistd.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <time.h>
#include <stdlib.h>
static uint64_t sc(const char *n){ uint64_t v=0; size_t s=sizeof v; if(sysctlbyname(n,&v,&s,NULL,0)) return (uint64_t)-1; return s==4?(uint32_t)v:v; }
int main(int argc,char**argv){
  int interval_ms = argc>1?atoi(argv[1]):20, iters = argc>2?atoi(argv[2]):150;
  vm_statistics64_data_t p={0}; uint64_t pg=0,pf=0; int ch_host=0, ch_sysctl=0, ch_grab=0;
  struct timespec t0; clock_gettime(CLOCK_MONOTONIC,&t0);
  for(int i=0;i<iters;i++){
    vm_statistics64_data_t s; mach_msg_type_number_t c=HOST_VM_INFO64_COUNT;
    host_statistics64(mach_host_self(),HOST_VM_INFO64,(host_info64_t)&s,&c);
    uint64_t f=sc("vm.page_free_count"), g=sc("vm.pages_grabbed");
    if(i){ if(s.free_count!=p.free_count||s.faults!=p.faults||s.zero_fill_count!=p.zero_fill_count) ch_host++; if(f!=pf) ch_sysctl++; if(g!=pg) ch_grab++; }
    p=s; pf=f; pg=g; usleep(interval_ms*1000);
  }
  struct timespec t1; clock_gettime(CLOCK_MONOTONIC,&t1);
  double el=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)/1e9;
  printf("interval=%dms iters=%d elapsed=%.2fs: host_statistics64 changed %d/%d times (%.1f/s); sysctl vm.page_free_count changed %d; vm.pages_grabbed changed %d\n",
    interval_ms, iters, el, ch_host, iters-1, ch_host/el, ch_sysctl, ch_grab);
  return 0;
}
