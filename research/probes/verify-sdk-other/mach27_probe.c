#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/host_info.h>
#include <mach/vm_statistics.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

static void vmstat(const char *tag){
  vm_statistics64_data_t v; memset(&v,0,sizeof v);
  mach_msg_type_number_t c=HOST_VM_INFO64_COUNT;
  kern_return_t kr=host_statistics64(mach_host_self(),HOST_VM_INFO64,(host_info64_t)&v,&c);
  printf("[%s] HOST_VM_INFO64 kr=%d count=%u (COUNT=%u REV6=%u)\n",tag,kr,c,(unsigned)HOST_VM_INFO64_COUNT,(unsigned)HOST_VM_INFO64_REV6_COUNT);
  printf("  free=%u active=%u inactive=%u wire=%u compressor_page_count=%u internal=%u external=%u\n",v.free_count,v.active_count,v.inactive_count,v.wire_count,v.compressor_page_count,v.internal_page_count,v.external_page_count);
  printf("  swap_count=%llu executable_count=%llu shared_region_count=%llu active_internal=%llu inactive_internal=%llu active_external=%llu inactive_external=%llu spec_created=%llu spec_activated=%llu\n",
    v.swap_count,v.executable_count,v.shared_region_count,v.active_internal_count,v.inactive_internal_count,v.active_external_count,v.inactive_external_count,v.speculative_pages_created,v.speculative_pages_activated);
}
int main(void){
  // HOST_CPU_COUNTERS_INFO via host_statistics64
  host_cpu_counters_info_data_t h; memset(&h,0,sizeof h);
  mach_msg_type_number_t c=HOST_CPU_COUNTERS_INFO_COUNT;
  kern_return_t kr=host_statistics64(mach_host_self(),HOST_CPU_COUNTERS_INFO,(host_info64_t)&h,&c);
  printf("host_statistics64(HOST_CPU_COUNTERS_INFO=%d) kr=%d (%s) count=%u/%u user=%llu sys=%llu idle=%llu cyc=%llu ins=%llu nj=%llu\n",HOST_CPU_COUNTERS_INFO,kr,mach_error_string(kr),c,(unsigned)HOST_CPU_COUNTERS_INFO_COUNT,h.user_time_mach,h.system_time_mach,h.idle_time_mach,h.cycles,h.instructions,h.energy_nj);
  // PROCESSOR_CPU_COUNTERS_INFO
  natural_t ncpu=0; processor_info_array_t arr=NULL; mach_msg_type_number_t n=0;
  kr=host_processor_info(mach_host_self(),PROCESSOR_CPU_COUNTERS_INFO,&ncpu,&arr,&n);
  printf("host_processor_info(PROCESSOR_CPU_COUNTERS_INFO) kr=%d (%s) ncpu=%u n=%u\n",kr,mach_error_string(kr),ncpu,n);
  if(kr==KERN_SUCCESS){ vm_deallocate(mach_task_self(),(vm_address_t)arr,n*sizeof(integer_t)); }
  kr=host_processor_info(mach_host_self(),PROCESSOR_CPU_LOAD_INFO,&ncpu,&arr,&n);
  printf("sanity host_processor_info(PROCESSOR_CPU_LOAD_INFO) kr=%d ncpu=%u\n",kr,ncpu);
  if(kr==KERN_SUCCESS){ vm_deallocate(mach_task_self(),(vm_address_t)arr,n*sizeof(integer_t)); }
  // processor ports via host_processors needs host_priv; try host_self as priv
  processor_array_t procs; mach_msg_type_number_t pc=0;
  kr=host_processors(mach_host_self(),&procs,&pc);
  printf("host_processors(host_self) kr=%d (%s) count=%u\n",kr,mach_error_string(kr),pc);
  vmstat("t0"); sleep(1); vmstat("t1");
  // rusage v6
  struct rusage_info_v6 ri; memset(&ri,0,sizeof ri);
  int r=proc_pid_rusage(getpid(),RUSAGE_INFO_V6,(rusage_info_t*)&ri);
  printf("proc_pid_rusage(self,V6) r=%d page_wait_time_mach=%llu page_cache_hits=%llu conclave_footprint=%llu energy_nj=%llu phys_footprint=%llu\n",r,ri.ri_page_wait_time_mach,ri.ri_page_cache_hits,ri.ri_conclave_footprint,ri.ri_energy_nj,ri.ri_phys_footprint);
  // other process: launchd (pid 1) and WindowServer? just pid 1 and a user proc (parent)
  memset(&ri,0,sizeof ri);
  r=proc_pid_rusage(1,RUSAGE_INFO_V6,(rusage_info_t*)&ri);
  printf("proc_pid_rusage(pid1,V6) r=%d errno-ish; energy_nj=%llu\n",r,ri.ri_energy_nj);
  memset(&ri,0,sizeof ri);
  r=proc_pid_rusage(getppid(),RUSAGE_INFO_V6,(rusage_info_t*)&ri);
  printf("proc_pid_rusage(ppid=%d,V6) r=%d page_wait=%llu page_cache_hits=%llu energy_nj=%llu\n",getppid(),r,ri.ri_page_wait_time_mach,ri.ri_page_cache_hits,ri.ri_energy_nj);
  return 0;
}
