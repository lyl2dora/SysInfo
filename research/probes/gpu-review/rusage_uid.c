// Review probe: which pids does proc_pid_rusage(RUSAGE_INFO_V6) allow, broken down by owner uid (same user vs other)?
// build: xcrun clang -O1 -o rusage_uid rusage_uid.c
#include <libproc.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
int main(void){ int pids[8192]; int n=proc_listallpids(pids,sizeof pids); uid_t me=getuid();
  int same_ok=0,same_fail=0,oth_ok=0,oth_fail=0,unk=0; 
  for(int i=0;i<n;i++){ struct proc_bsdshortinfo si; if(proc_pidinfo(pids[i],PROC_PIDT_SHORTBSDINFO,0,&si,sizeof si)!=sizeof si){unk++;continue;}
    struct rusage_info_v6 ri; int r=proc_pid_rusage(pids[i],RUSAGE_INFO_V6,(rusage_info_t*)&ri);
    if(si.pbsi_uid==me){ if(r==0) same_ok++; else same_fail++; } else { if(r==0){ oth_ok++; if(oth_ok<=5){ char nm[64]={0}; proc_name(pids[i],nm,64); printf("  other-uid readable: pid %d uid %d %s\n",pids[i],si.pbsi_uid,nm);} } else oth_fail++; } }
  printf("pids=%d same-uid ok=%d fail=%d | other-uid ok=%d fail=%d | shortinfo-unavailable=%d\n",n,same_ok,same_fail,oth_ok,oth_fail,unk); return 0; }
