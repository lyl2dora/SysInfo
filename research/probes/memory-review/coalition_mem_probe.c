// coalition_mem_probe.c - does coalition_info_resource_usage carry any memory figure? Compare its u64 slots 33..49 with
// the sum of members' ri_phys_footprint / lifetime max for SAME-UID resource coalitions (where members are readable).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <unistd.h>
struct pidcoal { uint64_t coalition_id[2]; uint64_t r1,r2,r3; };
typedef int (*cru_fn)(uint64_t, void*, size_t);
int main(void){ cru_fn cru=(cru_fn)dlsym(RTLD_DEFAULT,"coalition_info_resource_usage");
  int n=proc_listallpids(NULL,0); pid_t *p=calloc(n+64,4); n=proc_listallpids(p,(n+64)*4);
  const char *want[]={"Terminal","Xcode","News","Finder","com.apple.Virtualization.VirtualMachine",NULL};
  for(int w=0;want[w];w++){ pid_t lead=-1; for(int i=0;i<n;i++){ char path[4096]={0}; if(proc_pidpath(p[i],path,sizeof path)>0){ char*b=strrchr(path,'/'); if(b&&!strcmp(b+1,want[w])){lead=p[i];break;} } }
    if(lead<0){ printf("%s not found\n",want[w]); continue; }
    struct pidcoal pc={0}; proc_pidinfo(lead,20,0,&pc,sizeof pc); uint64_t cid=pc.coalition_id[0];
    uint64_t sumfp=0,summax=0,sumres=0; int mem=0, unread=0;
    for(int i=0;i<n;i++){ struct pidcoal q={0}; if(proc_pidinfo(p[i],20,0,&q,sizeof q)!=sizeof q||q.coalition_id[0]!=cid) continue; mem++;
      struct rusage_info_v6 ru; if(proc_pid_rusage(p[i],RUSAGE_INFO_V6,(rusage_info_t*)&ru)==0){ sumfp+=ru.ri_phys_footprint; summax+=ru.ri_lifetime_max_phys_footprint; sumres+=ru.ri_resident_size;} else unread++; }
    uint64_t u[128]={0}; cru(cid,u,sizeof u);
    printf("%-10.10s pid %d res_coal %llu members=%d unreadable=%d | sum footprint=%.1f MiB sum lifemax=%.1f MiB | slots:",want[w],lead,cid,mem,unread,sumfp/1048576.0,summax/1048576.0);
    for(int k=33;k<50;k++) if(u[k]) printf(" [%d]=%llu(%.1fMiB)",k,u[k],u[k]/1048576.0); printf("\n"); }
  return 0; }
