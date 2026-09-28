// rl_log.c - log every HOST_VM_INFO64 result with a mach_absolute_time stamp (ns), for cross-process cache analysis.
// usage: rl_log <interval_us> <count> <outfile>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
int main(int argc,char**argv){ int iv=atoi(argv[1]), n=atoi(argv[2]); FILE*f=fopen(argv[3],"w");
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  for(int i=0;i<n;i++){ vm_statistics64_data_t s; mach_msg_type_number_t c=HOST_VM_INFO64_COUNT;
    uint64_t t=mach_absolute_time(); host_statistics64(mach_host_self(),HOST_VM_INFO64,(host_info64_t)&s,&c);
    fprintf(f,"%llu %llu %llu %llu %u\n",(unsigned long long)(t*tb.numer/tb.denom),s.faults,s.zero_fill_count,s.cow_faults,s.free_count); usleep(iv);} 
  fclose(f); return 0; }
