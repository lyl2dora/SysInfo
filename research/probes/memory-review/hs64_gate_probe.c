// hs64_gate_probe.c - does host_statistics64() return KERN_INVALID_ARGUMENT for flavors the kernel DOES implement
// (32-bit flavors that host_statistics64 forwards to host_statistics)? If so, kr=4 for HOST_CPU_COUNTERS_INFO (8)
// from a non-platform binary does not by itself prove the flavor is unimplemented (XNU's third-party rate-limit gate
// validates flavors against its own cache table before dispatch).
#include <stdio.h>
#include <string.h>
#include <mach/mach.h>
int main(void){ int fl[]={HOST_LOAD_INFO,HOST_VM_INFO,HOST_CPU_LOAD_INFO,HOST_VM_INFO64,HOST_EXTMOD_INFO64,HOST_EXPIRED_TASK_INFO,7,8,9};
  for(unsigned i=0;i<sizeof fl/sizeof fl[0];i++){ uint64_t b64[64]; memset(b64,0,sizeof b64); mach_msg_type_number_t c=64*2; kern_return_t k=host_statistics64(mach_host_self(),fl[i],(host_info64_t)b64,&c);
    uint32_t b32[128]; mach_msg_type_number_t c2=128; kern_return_t k2=host_statistics(mach_host_self(),fl[i],(host_info_t)b32,&c2);
    printf("flavor %d: host_statistics64 kr=%d count_out=%u | host_statistics kr=%d count_out=%u\n",fl[i],k,k?0:c,k2,k2?0:c2); }
  return 0; }
