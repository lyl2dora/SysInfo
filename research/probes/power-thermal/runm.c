// runm.c - run a command (own child only), sample the child's proc_pid_rusage (ri_energy_nj, ri_penergy_nj, cpu/P-core time)
// at 1 Hz, and read the final totals from the zombie (waitid WNOWAIT) before reaping. Read-only w.r.t. the system.
// build: xcrun clang -O2 runm.c -o runm ; usage: runm <label> <cmd> [args...]
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
static double wall(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
static mach_timebase_info_data_t tb;
static double ticks2s(uint64_t t){ return (double)t*tb.numer/tb.denom/1e9; }
static void pr(const char*lab, pid_t p, double t){ struct rusage_info_v6 r; if(proc_pid_rusage(p,RUSAGE_INFO_V6,(rusage_info_t*)&r)){ printf("%s %.3f pid=%d rusage-failed\n",lab,t,p); return; }
  printf("%s %.3f pid=%d energy_nj=%llu penergy_nj=%llu user_s=%.3f sys_s=%.3f user_ptime_s=%.3f sys_ptime_s=%.3f instr=%llu cycles=%llu pinstr=%llu pcycles=%llu\n",
    lab,t,p,r.ri_energy_nj,r.ri_penergy_nj,ticks2s(r.ri_user_time),ticks2s(r.ri_system_time),ticks2s(r.ri_user_ptime),ticks2s(r.ri_system_ptime),
    r.ri_instructions,r.ri_cycles,r.ri_pinstructions,r.ri_pcycles); fflush(stdout); }
int main(int argc,char**argv){ mach_timebase_info(&tb); if(argc<3) return 1;
  pid_t c=fork(); if(c==0){ execv(argv[2],argv+2); perror("exec"); _exit(127);} 
  printf("RUNM_START %.3f label=%s pid=%d\n",wall(),argv[1],c); fflush(stdout);
  while(1){ siginfo_t si={0}; int r=waitid(P_PID,c,&si,WEXITED|WNOHANG|WNOWAIT); if(r==0 && si.si_pid==c) break; pr("S",c,wall()); usleep(1000000); }
  pr("FINAL",c,wall()); int st; waitpid(c,&st,0); printf("RUNM_END %.3f label=%s status=%d\n",wall(),argv[1],st); return 0; }
