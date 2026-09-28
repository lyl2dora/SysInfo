// coalition_vs_top.c - for FOREIGN (root / other-uid) processes that are the only member of their resource coalition,
// print coalition_info_resource_usage slot 40 (== sum of members' phys_footprint, see coalition_mem_probe.txt) next to pid,
// so it can be compared with the setuid /usr/bin/top MEM column taken at the same time.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
struct pidcoal { uint64_t coalition_id[2]; uint64_t r1,r2,r3; };
typedef int (*cru_fn)(uint64_t, void*, size_t);
int main(void){ cru_fn cru=(cru_fn)dlsym(RTLD_DEFAULT,"coalition_info_resource_usage"); uid_t me=getuid();
  int n=proc_listallpids(NULL,0); pid_t *p=calloc(n+64,4); n=proc_listallpids(p,(n+64)*4);
  uint64_t *cid=calloc(n,8); for(int i=0;i<n;i++){ struct pidcoal q={0}; if(proc_pidinfo(p[i],20,0,&q,sizeof q)==sizeof q) cid[i]=q.coalition_id[0]; }
  int shown=0, single=0, foreign=0;
  for(int i=0;i<n;i++){ struct proc_bsdshortinfo s; if(proc_pidinfo(p[i],PROC_PIDT_SHORTBSDINFO,0,&s,sizeof s)!=sizeof s || s.pbsi_uid==me) continue; foreign++;
    int members=0; for(int j=0;j<n;j++) if(cid[j]==cid[i]) members++;
    if(members!=1) continue; single++;
    uint64_t u[128]={0}; if(cru(cid[i],u,sizeof u)) continue;
    { printf("pid %-6d uid %-4d %-18s coal %-6llu footprint(slot40)=%.1f MiB\n",p[i],s.pbsi_uid,s.pbsi_comm,cid[i],u[40]/1048576.0); shown++; } }
  printf("foreign processes=%d, of which sole member of their resource coalition=%d\n",foreign,single); return 0; }
