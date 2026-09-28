// rl_burst.c - once per second, 10 back-to-back HOST_VM_INFO64 calls 2 ms apart; count distinct results per burst.
// Per-task budget => every burst starts a fresh window for this task => >=2 fresh (distinct) results.
// System-wide budget + another process hammering => bursts mostly get only the cached copy (1 distinct).
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach.h>
int main(int argc,char**argv){ int secs=argc>1?atoi(argv[1]):10; int one=0; printf("burst distinct counts:");
  for(int t=0;t<secs;t++){ uint64_t seen[10]; int d=0;
    for(int k=0;k<10;k++){ vm_statistics64_data_t s; mach_msg_type_number_t c=HOST_VM_INFO64_COUNT;
      host_statistics64(mach_host_self(),HOST_VM_INFO64,(host_info64_t)&s,&c);
      uint64_t key=s.faults*31+s.zero_fill_count*7+s.free_count; int dup=0; for(int j=0;j<d;j++) if(seen[j]==key) dup=1; if(!dup) seen[d++]=key; usleep(2000);} 
    printf(" %d",d); if(d==1) one++; fflush(stdout); usleep(1000000); }
  printf("\nbursts with only 1 distinct result (fully served from cache): %d/%d\n",one,secs); return 0; }
