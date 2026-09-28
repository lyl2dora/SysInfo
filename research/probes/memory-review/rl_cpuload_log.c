// rl_cpuload_log.c - same cross-process cache test as rl_log.c but for host_statistics(HOST_CPU_LOAD_INFO) (used by Stats' CPU module)
// and, for contrast, host_processor_info(PROCESSOR_CPU_LOAD_INFO) summed over CPUs (not part of the host_statistics rate limiter).
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
int main(int argc,char**argv){ int iv=atoi(argv[1]), n=atoi(argv[2]); FILE*f=fopen(argv[3],"w"); mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  for(int i=0;i<n;i++){ host_cpu_load_info_data_t cl; mach_msg_type_number_t c=HOST_CPU_LOAD_INFO_COUNT; uint64_t t=mach_absolute_time();
    host_statistics(mach_host_self(),HOST_CPU_LOAD_INFO,(host_info_t)&cl,&c);
    natural_t ncpu; processor_info_array_t pi; mach_msg_type_number_t pc; unsigned long long pu=0;
    if(host_processor_info(mach_host_self(),PROCESSOR_CPU_LOAD_INFO,&ncpu,&pi,&pc)==KERN_SUCCESS){ for(natural_t k=0;k<ncpu;k++) pu+=pi[k*CPU_STATE_MAX+CPU_STATE_USER]+pi[k*CPU_STATE_MAX+CPU_STATE_SYSTEM]+pi[k*CPU_STATE_MAX+CPU_STATE_IDLE]; vm_deallocate(mach_task_self(),(vm_address_t)pi,pc*sizeof(int)); }
    fprintf(f,"%llu %u %u %u %u %llu\n",(unsigned long long)(t*tb.numer/tb.denom),cl.cpu_ticks[0],cl.cpu_ticks[1],cl.cpu_ticks[2],cl.cpu_ticks[3],pu); usleep(iv);} fclose(f); return 0; }
