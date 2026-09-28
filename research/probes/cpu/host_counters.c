// Probe: NEW macOS 27 SDK host_statistics64(HOST_CPU_COUNTERS_INFO=8): host-wide user/system/idle mach time, cycles, instructions, energy_nj.
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
static atomic_int stop_flag=0; static void* spin(void* a){ volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
static kern_return_t get(struct host_cpu_counters_info* h){ mach_msg_type_number_t c = HOST_CPU_COUNTERS_INFO_COUNT;
  kern_return_t kr = host_statistics64(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info64_t)h, &c);
  if(kr) { kr = host_statistics(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info_t)h, &c); if(kr) printf("host_statistics(HOST_CPU_COUNTERS_INFO) also kr=%d (%s)\n", kr, mach_error_string(kr)); }
  return kr; }
int main(){
  struct host_cpu_counters_info a={0}, b={0}; mach_msg_type_number_t c = HOST_CPU_COUNTERS_INFO_COUNT;
  kern_return_t kr = host_statistics64(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info64_t)&a, &c);
  printf("host_statistics64(HOST_CPU_COUNTERS_INFO) kr=%d (%s) count=%u\n", kr, mach_error_string(kr), c);
  if(get(&a)) return 0;
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double k = tb.numer/(double)tb.denom/1e9;
  printf("abs: user=%.1fs sys=%.1fs idle=%.1fs cycles=%llu instr=%llu energy=%.1fJ\n", a.user_time_mach*k, a.system_time_mach*k, a.idle_time_mach*k, a.cycles, a.instructions, a.energy_nj/1e9);
  for(int phase=0; phase<2; phase++){
    pthread_t th[18]; if(phase){ for(int i=0;i<18;i++) pthread_create(&th[i],NULL,spin,NULL); usleep(300000); }
    get(&a); uint64_t t0=mach_absolute_time(); sleep(1); get(&b); double dt=(mach_absolute_time()-t0)*k;
    if(phase){ atomic_store(&stop_flag,1); for(int i=0;i<18;i++) pthread_join(th[i],NULL); }
    double u=(b.user_time_mach-a.user_time_mach)*k, s=(b.system_time_mach-a.system_time_mach)*k, id=(b.idle_time_mach-a.idle_time_mach)*k;
    printf("%s: user=%.2fs sys=%.2fs idle=%.2fs busy=%.1f%% cycles=%.3e instr=%.3e energy=%.2f J => %.2f W\n", phase?"LOADED(18 thr)":"IDLE", u, s, id, 100*(u+s)/(u+s+id), (double)(b.cycles-a.cycles), (double)(b.instructions-a.instructions), (b.energy_nj-a.energy_nj)/1e9, (b.energy_nj-a.energy_nj)/1e9/dt);
  }
  return 0;
}
