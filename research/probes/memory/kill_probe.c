// kill_probe.c - process termination capability as a normal user.
// Only real signal sent: SIGTERM/SIGKILL to a /bin/sleep child we spawn ourselves.
// For foreign processes only kill(pid, 0) is used (permission check, NO signal delivered).
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/sysctl.h>
extern char **environ;
static uid_t uid_of(pid_t p){ struct kinfo_proc kp; size_t l=sizeof kp; int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,p}; if(sysctl(mib,4,&kp,&l,NULL,0)||!l) return (uid_t)-1; return kp.kp_eproc.e_ucred.cr_uid; }
static pid_t find(const char*name){ pid_t pids[4096]; int n=proc_listallpids(pids,sizeof pids)/1; for(int i=0;i<n;i++){ char nm[64]={0}; proc_name(pids[i],nm,sizeof nm); if(!strcmp(nm,name)) return pids[i]; } return -1; }
static void probe0(const char*label,pid_t p){ errno=0; int r=kill(p,0); printf("kill(%d [%s, uid=%d], 0) -> %d errno=%d (%s)\n",p,label,uid_of(p),r,r?errno:0,r?strerror(errno):"permitted"); }
int main(void){
  pid_t child; char *argv[]={"/bin/sleep","300",NULL};
  int rc=posix_spawn(&child,"/bin/sleep",NULL,NULL,argv,environ);
  printf("spawned /bin/sleep child pid=%d rc=%d\n",child,rc);
  probe0("own child",child);
  probe0("launchd (root)",1);
  pid_t ws=find("WindowServer"); if(ws>0) probe0("WindowServer",ws);
  pid_t fi=find("Finder"); if(fi>0) probe0("Finder (same user, not ours)",fi);
  pid_t cf=find("coreaudiod"); if(cf>0) probe0("coreaudiod",cf);
  // responsibility_get_pid_responsible_for_pid (Stats readers.swift:209-226)
  typedef int (*rfn)(int); rfn f=(rfn)dlsym(RTLD_DEFAULT,"responsibility_get_pid_responsible_for_pid");
  printf("dlsym(responsibility_get_pid_responsible_for_pid)=%p\n",(void*)f);
  if(f){ printf("  responsible(child)=%d responsible(self)=%d responsible(1)=%d responsible(WindowServer)=%d\n",f(child),f(getpid()),f(1),ws>0?f(ws):-2);
    pid_t pids[4096]; int n=proc_listallpids(pids,sizeof pids); int ok=0,neg=0,diff=0; for(int i=0;i<n;i++){ int r=f(pids[i]); if(r==-1)neg++; else {ok++; if(r!=pids[i]) diff++;} }
    printf("  over %d pids: resolved=%d (of which %d differ from pid) failed(-1)=%d\n",n,ok,diff,neg); }
  // terminate own child: SIGTERM, reap
  errno=0; int kr=kill(child,SIGTERM); int st=0; pid_t w=waitpid(child,&st,0);
  printf("kill(child,SIGTERM) -> %d errno=%d; waitpid -> %d signaled=%d termsig=%d\n",kr,kr?errno:0,w,WIFSIGNALED(st),WIFSIGNALED(st)?WTERMSIG(st):0);
  // Stats-style: syncShell("kill -9 <pid>") on a second own child
  posix_spawn(&child,"/bin/sleep",NULL,NULL,argv,environ);
  char cmd[64]; snprintf(cmd,sizeof cmd,"kill -9 %d",child); int sr=system(cmd); w=waitpid(child,&st,0);
  printf("Stats-style shell '%s' -> system()=%d; waitpid -> %d termsig=%d\n",cmd,sr,w,WIFSIGNALED(st)?WTERMSIG(st):0);
  return 0;
}
