// rl_hammer.c - second, independent process that polls HOST_VM_INFO64 every 2 ms for N seconds (to test whether the
// XNU host_statistics rate-limit budget/cache is per-task or system-wide).
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach.h>
int main(int argc,char**argv){ int secs=argc>1?atoi(argv[1]):12; int n=secs*500, fresh=0; uint64_t pf=0;
  for(int i=0;i<n;i++){ vm_statistics64_data_t s; mach_msg_type_number_t c=HOST_VM_INFO64_COUNT;
    host_statistics64(mach_host_self(),HOST_VM_INFO64,(host_info64_t)&s,&c); if(s.faults!=pf) fresh++; pf=s.faults; usleep(2000);} 
  printf("hammer: %d calls, %d changed results (%.1f/s)\n",n,fresh,fresh/(double)secs); return 0; }
