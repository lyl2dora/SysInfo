// name_probe.c - which name APIs work for foreign (root / other uid) processes; kill(pid,0) on WindowServer
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <libproc.h>
#include <sys/sysctl.h>
int main(void){
  int pids[]={1,172};
  for(int i=0;i<2;i++){ int p=pids[i]; char nm[256]={0}; errno=0; int r=proc_name(p,nm,sizeof nm);
    printf("pid %d: proc_name rc=%d errno=%d name='%s'\n",p,r,r<=0?errno:0,nm);
    struct proc_bsdshortinfo s; r=proc_pidinfo(p,PROC_PIDT_SHORTBSDINFO,0,&s,sizeof s); printf("  SHORTBSDINFO rc=%d comm='%s' uid=%d\n",r,r>0?s.pbsi_comm:"",r>0?s.pbsi_uid:-1);
    char path[PROC_PIDPATHINFO_MAXSIZE]={0}; r=proc_pidpath(p,path,sizeof path); printf("  proc_pidpath rc=%d '%s'\n",r,path);
    struct kinfo_proc kp; size_t l=sizeof kp; int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,p}; sysctl(mib,4,&kp,&l,NULL,0); printf("  KERN_PROC_PID p_comm='%s'\n",kp.kp_proc.p_comm);
    errno=0; r=kill(p,0); printf("  kill(%d,0) -> %d errno=%d\n",p,r,r?errno:0);
  }
  return 0;
}
