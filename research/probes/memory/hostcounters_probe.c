// hostcounters_probe.c - new in macOS 27 SDK: host_statistics64(HOST_CPU_COUNTERS_INFO) (side finding from SDK diff; CPU domain)
#include <stdio.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
int main(void){
  host_cpu_counters_info_data_t a,b; mach_msg_type_number_t c=HOST_CPU_COUNTERS_INFO_COUNT;
  kern_return_t kr=host_statistics64(mach_host_self(),HOST_CPU_COUNTERS_INFO,(host_info64_t)&a,&c);
  printf("HOST_CPU_COUNTERS_INFO kr=%d (%s) count=%u\n",kr,mach_error_string(kr),c); if(kr) return 1;
  sleep(1); c=HOST_CPU_COUNTERS_INFO_COUNT; host_statistics64(mach_host_self(),HOST_CPU_COUNTERS_INFO,(host_info64_t)&b,&c);
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double k=(double)tb.numer/tb.denom/1e9;
  double u=(b.user_time_mach-a.user_time_mach)*k, s=(b.system_time_mach-a.system_time_mach)*k, i=(b.idle_time_mach-a.idle_time_mach)*k;
  printf("1s delta: user=%.3fs sys=%.3fs idle=%.3fs (sum %.2f cpu-s ~ 18 cores) busy=%.1f%% cycles=%llu instr=%llu energy=%.3f J (%.2f W)\n",
    u,s,i,u+s+i,100*(u+s)/(u+s+i),b.cycles-a.cycles,b.instructions-a.instructions,(b.energy_nj-a.energy_nj)/1e9,(b.energy_nj-a.energy_nj)/1e9);
  return 0;
}
