#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>
struct pidcoal { uint64_t coalition_id[2]; uint64_t r1, r2, r3; };
int main(void){ struct pidcoal pc={0}; proc_pidinfo(getpid(),20,0,&pc,sizeof pc);
 int (*pl)(uint64_t, void*, size_t*) = dlsym(RTLD_DEFAULT,"coalition_info_pid_list"); int (*cru)(uint64_t,void*,size_t)=dlsym(RTLD_DEFAULT,"coalition_info_resource_usage");
 pid_t b[256]; size_t sz=sizeof b; pl(pc.coalition_id[0],b,&sz); uint64_t u[50]; cru(pc.coalition_id[0],u,sizeof u);
 printf("pid %d ppid %d res_coal %llu jetsam %llu members:", getpid(), getppid(), pc.coalition_id[0], pc.coalition_id[1]); for(size_t i=0;i<sz/sizeof(pid_t);i++) printf(" %d",b[i]); printf(" | tasks_started=%llu exited=%llu time_nonempty=%llu\n",u[0],u[1],u[2]); return 0; }
