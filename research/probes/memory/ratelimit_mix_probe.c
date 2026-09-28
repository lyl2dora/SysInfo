// ratelimit_mix_probe.c - does calling OTHER host_statistics flavors (CPU load) in the same second make HOST_VM_INFO64 stale?
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
int main(int argc,char**argv){
  int extra = argc>1?atoi(argv[1]):0, secs = argc>2?atoi(argv[2]):8;
  vm_statistics64_data_t prev; memset(&prev,0,sizeof prev); int stale=0;
  for(int i=0;i<secs;i++){
    for(int k=0;k<extra;k++){ host_cpu_load_info_data_t cl; mach_msg_type_number_t c=HOST_CPU_LOAD_INFO_COUNT;
      host_statistics(mach_host_self(),HOST_CPU_LOAD_INFO,(host_info_t)&cl,&c); }
    vm_statistics64_data_t s; mach_msg_type_number_t c=HOST_VM_INFO64_COUNT;
    host_statistics64(mach_host_self(),HOST_VM_INFO64,(host_info64_t)&s,&c);
    if(i && memcmp(&s,&prev,sizeof s)==0) stale++;
    prev=s; sleep(1);
  }
  printf("extra HOST_CPU_LOAD_INFO calls per second=%d: HOST_VM_INFO64 stale (identical to 1s earlier) %d/%d samples\n", extra, stale, secs-1);
  return 0;
}
