// percpu.c - per-logical-CPU busy % over an interval (host_processor_info), to see where a given own load runs. Read-only.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach.h>
static void snap(unsigned *n, processor_cpu_load_info_t *p){ mach_msg_type_number_t c; host_processor_info(mach_host_self(),PROCESSOR_CPU_LOAD_INFO,n,(processor_info_array_t*)p,&c); }
int main(int c,char**v){ unsigned n; processor_cpu_load_info_t a,b; snap(&n,&a); sleep(atoi(v[1])); snap(&n,&b);
  for(unsigned i=0;i<n;i++){ double u=0,t=0; for(int k=0;k<CPU_STATE_MAX;k++){ double d=b[i].cpu_ticks[k]-a[i].cpu_ticks[k]; t+=d; if(k!=CPU_STATE_IDLE) u+=d; } printf("cpu%-2u %5.1f%%%s",i,t?100*u/t:0,(i%6==5)?"\n":"  "); } return 0; }
