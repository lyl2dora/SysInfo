// Probe: what IS readable for root-owned processes as uid 501: proc_name vs PROC_PIDT_SHORTBSDINFO.pbsi_comm vs proc_pidpath vs
// sysctl KERN_PROC_PID kinfo_proc (p_comm, p_pctcpu, p_cpticks, p_estcpu) vs PROC_PIDTASKINFO / proc_pid_rusage / KERN_PROCARGS2.
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
int main(){
  int pids[] = {1, 100, 142, 243, 206, 0};
  for(int i=0; pids[i]; i++){
    int pid = pids[i]; char nm[256]=""; int nr = proc_name(pid, nm, sizeof nm); int ne = errno;
    struct proc_bsdshortinfo bi; int br = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bi, sizeof bi);
    char path[4096]=""; int pr = proc_pidpath(pid, path, sizeof path);
    struct kinfo_proc kp; size_t sz = sizeof kp; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid}; int sr = sysctl(mib, 4, &kp, &sz, NULL, 0);
    struct proc_taskinfo ti; errno=0; int tr = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti); int te = errno;
    char args[4096]; size_t asz = sizeof args; int amib[3] = {CTL_KERN, KERN_PROCARGS2, pid}; errno=0; int ar = sysctl(amib, 3, args, &asz, NULL, 0); int ae = errno;
    printf("pid=%d proc_name=%d('%s',errno %d) shortbsd=%d(comm='%s' uid=%u) pidpath=%d('%s') kinfo=%d(p_comm='%s' p_pctcpu=%u p_cpticks=%d p_estcpu=%u) taskinfo=%d(errno %d) procargs2=%d(errno %d)\n",
      pid, nr, nm, ne, br, br>0?bi.pbsi_comm:"", br>0?bi.pbsi_uid:0, pr, path, sr, sr==0?kp.kp_proc.p_comm:"", sr==0?kp.kp_proc.p_pctcpu:0, sr==0?kp.kp_proc.p_cpticks:0, sr==0?kp.kp_proc.p_estcpu:0, tr, te, ar, ae);
  }
  return 0;
}
