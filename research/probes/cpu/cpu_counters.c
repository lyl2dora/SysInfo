// Probe: NEW macOS 27 SDK flavor host_processor_info(PROCESSOR_CPU_COUNTERS_INFO) — per-CPU user/system/idle mach time,
// cycles, instructions, energy_nj. Also tries PROCESSOR_TEMPERATURE (0x10000002) via host_processor_info and processor_info.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
static atomic_int stop_flag = 0;
static void* spin(void* a){ volatile double x=1; while(!atomic_load(&stop_flag)) x = x*1.0000001+0.5; return NULL; }
static int get(struct processor_cpu_counters_info* out, int max){
  natural_t n=0; processor_info_array_t info=NULL; mach_msg_type_number_t cnt=0;
  kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_COUNTERS_INFO, &n, &info, &cnt);
  if(kr!=KERN_SUCCESS){ printf("host_processor_info(PROCESSOR_CPU_COUNTERS_INFO) kr=%d (%s)\n", kr, mach_error_string(kr)); return -1; }
  static int once=0; if(!once){ once=1; printf("ncpu=%u cnt=%u (ints) => %u ints/cpu, struct=%zu ints\n", n, cnt, n?cnt/n:0, sizeof(struct processor_cpu_counters_info)/4); }
  for(natural_t i=0;i<n && (int)i<max;i++) memcpy(&out[i], ((char*)info) + i*sizeof(struct processor_cpu_counters_info), sizeof(struct processor_cpu_counters_info));
  vm_deallocate(mach_task_self(), (vm_address_t)info, cnt*sizeof(integer_t));
  return (int)n;
}
static void show(const char* title, struct processor_cpu_counters_info* a, struct processor_cpu_counters_info* b, int n, double dt){
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  printf("\n== %s (dt=%.3fs) ==\n", title, dt);
  double totE=0, eM=0, eS=0;
  for(int i=0;i<n;i++){
    double u=(b[i].user_time_mach-a[i].user_time_mach)*tb.numer/(double)tb.denom/1e9;
    double s=(b[i].system_time_mach-a[i].system_time_mach)*tb.numer/(double)tb.denom/1e9;
    double id=(b[i].idle_time_mach-a[i].idle_time_mach)*tb.numer/(double)tb.denom/1e9;
    double cyc=(double)(b[i].cycles-a[i].cycles), ins=(double)(b[i].instructions-a[i].instructions);
    double e=(double)(b[i].energy_nj-a[i].energy_nj)/1e9;
    totE+=e; if(i<12) eM+=e; else eS+=e;
    printf(" cpu%-2d %s user=%.3fs sys=%.3fs idle=%.3fs busy=%5.1f%%  cycles=%.3e (%.0f MHz eff over busy) instr=%.3e IPC=%.2f  energy=%.3f J (%.2f W)\n",
      i, i<12?"M":"S", u, s, id, 100*(u+s)/((u+s+id)>0?(u+s+id):1), cyc, (u+s)>0? cyc/(u+s)/1e6:0, ins, cyc>0? ins/cyc:0, e, e/dt);
  }
  printf(" TOTAL energy %.3f J => %.2f W  (M cores %.2f W, S cores %.2f W)\n", totE, totE/dt, eM/dt, eS/dt);
}
int main(){
  struct processor_cpu_counters_info a[64], b[64];
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); printf("timebase %u/%u\n", tb.numer, tb.denom);
  int n = get(a,64); if(n<0) goto temp;
  printf("absolute cpu0: user=%llu sys=%llu idle=%llu cycles=%llu instr=%llu energy_nj=%llu\n", a[0].user_time_mach, a[0].system_time_mach, a[0].idle_time_mach, a[0].cycles, a[0].instructions, a[0].energy_nj);
  printf("absolute cpu12: user=%llu sys=%llu idle=%llu cycles=%llu instr=%llu energy_nj=%llu\n", a[12].user_time_mach, a[12].system_time_mach, a[12].idle_time_mach, a[12].cycles, a[12].instructions, a[12].energy_nj);
  uint64_t t0=mach_absolute_time(); sleep(1); get(b,64); uint64_t t1=mach_absolute_time();
  show("IDLE", a, b, n, (t1-t0)*tb.numer/(double)tb.denom/1e9);
  { pthread_t th[18]; for(int i=0;i<18;i++) pthread_create(&th[i],NULL,spin,NULL); usleep(300000);
    get(a,64); t0=mach_absolute_time(); sleep(1); get(b,64); t1=mach_absolute_time();
    atomic_store(&stop_flag,1); for(int i=0;i<18;i++) pthread_join(th[i],NULL);
    show("LOADED 18 threads", a, b, n, (t1-t0)*tb.numer/(double)tb.denom/1e9); }
temp:
  { natural_t nn=0; processor_info_array_t info=NULL; mach_msg_type_number_t cnt=0;
    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_TEMPERATURE, &nn, &info, &cnt);
    printf("\nhost_processor_info(PROCESSOR_TEMPERATURE) kr=%d (%s) n=%u cnt=%u\n", kr, mach_error_string(kr), nn, cnt);
    if(kr==KERN_SUCCESS){ for(natural_t i=0;i<cnt;i++) printf(" %d", info[i]); printf("\n"); }
    processor_array_t procs; mach_msg_type_number_t pc=0;
    kr = host_processors(mach_host_self(), &procs, &pc);
    printf("host_processors kr=%d (%s) (needs host_priv) \n", kr, mach_error_string(kr));
  }
  return 0;
}
