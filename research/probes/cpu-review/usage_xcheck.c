// Review probe: HOST_CPU_LOAD_INFO over a 5 s window (compare with iostat/top run concurrently), plus simultaneous
// getloadavg / HOST_LOAD_INFO / processor_set LOAD_INFO / task+thread counts. Read-only.
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static void cpu(unsigned* t){ host_cpu_load_info_data_t d; mach_msg_type_number_t c=HOST_CPU_LOAD_INFO_COUNT; host_statistics(mach_host_self(),HOST_CPU_LOAD_INFO,(host_info_t)&d,&c); for(int i=0;i<4;i++) t[i]=d.cpu_ticks[i]; }
int main(){
  unsigned a[4], b[4]; cpu(a); sleep(5); cpu(b);
  double u=b[CPU_STATE_USER]-a[CPU_STATE_USER], s=b[CPU_STATE_SYSTEM]-a[CPU_STATE_SYSTEM], i=b[CPU_STATE_IDLE]-a[CPU_STATE_IDLE], n=b[CPU_STATE_NICE]-a[CPU_STATE_NICE], t=u+s+i+n;
  printf("HOST_CPU_LOAD_INFO 5s: user=%.1f%% sys=%.1f%% idle=%.1f%% nice=%.1f%% ticks=%.0f\n", 100*u/t, 100*s/t, 100*i/t, 100*n/t, t);
  double la[3]; getloadavg(la,3);
  host_load_info_data_t hl; mach_msg_type_number_t c=HOST_LOAD_INFO_COUNT; host_statistics(mach_host_self(),HOST_LOAD_INFO,(host_info_t)&hl,&c);
  processor_set_name_t ps; processor_set_default(mach_host_self(),&ps); processor_set_load_info_data_t pl; c=PROCESSOR_SET_LOAD_INFO_COUNT; host_t h; processor_set_statistics(ps,PROCESSOR_SET_LOAD_INFO,(processor_set_info_t)&pl,&c);
  printf("getloadavg: %.2f %.2f %.2f\n", la[0],la[1],la[2]);
  printf("HOST_LOAD_INFO avenrun/1000: %.2f %.2f %.2f  mach_factor/1000: %.2f %.2f %.2f\n", hl.avenrun[0]/1000.0, hl.avenrun[1]/1000.0, hl.avenrun[2]/1000.0, hl.mach_factor[0]/1000.0, hl.mach_factor[1]/1000.0, hl.mach_factor[2]/1000.0);
  printf("PROCESSOR_SET_LOAD_INFO: tasks=%d threads=%d load_average=%.2f mach_factor=%.2f\n", pl.task_count, pl.thread_count, pl.load_average/1000.0, pl.mach_factor/1000.0);
  fflush(stdout); return 0;
}
