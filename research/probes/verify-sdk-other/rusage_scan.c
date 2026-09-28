#include <stdio.h>
#include <string.h>
#include <libproc.h>
#include <sys/resource.h>
#include <errno.h>
int main(void){
  int pids[8192]; int n=proc_listallpids(pids,sizeof pids)/1; int ok=0,fail=0,nzwait=0,nzhits=0,nzconc=0;
  uint64_t maxwait=0,maxhits=0; int pw=0,ph=0;
  for(int i=0;i<n;i++){ struct rusage_info_v6 ri; memset(&ri,0,sizeof ri);
    if(proc_pid_rusage(pids[i],RUSAGE_INFO_V6,(rusage_info_t*)&ri)==0){ok++;
      if(ri.ri_page_wait_time_mach){nzwait++; if(ri.ri_page_wait_time_mach>maxwait){maxwait=ri.ri_page_wait_time_mach;pw=pids[i];}}
      if(ri.ri_page_cache_hits){nzhits++; if(ri.ri_page_cache_hits>maxhits){maxhits=ri.ri_page_cache_hits;ph=pids[i];}}
      if(ri.ri_conclave_footprint) nzconc++;
    } else fail++; }
  char nm[256];
  printf("pids=%d ok=%d fail(EPERM etc)=%d nonzero page_wait=%d nonzero page_cache_hits=%d nonzero conclave_fp=%d\n",n,ok,fail,nzwait,nzhits,nzconc);
  proc_name(pw,nm,sizeof nm); printf("max page_wait_time_mach=%llu pid=%d (%s)\n",maxwait,pw,nm);
  proc_name(ph,nm,sizeof nm); printf("max page_cache_hits=%llu pid=%d (%s)\n",maxhits,ph,nm);
  return 0;}
