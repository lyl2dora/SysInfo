// foreign_footprint_scan.c - no-root per-process footprint for ALL pids: proc_pid_rusage for same-uid; for foreign pids use
// resource-coalition footprint (coalition_info_resource_usage slot 40) minus readable members. Reports coverage + scan cost.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <mach/mach_time.h>
struct pidcoal { uint64_t coalition_id[2]; uint64_t r1,r2,r3; };
typedef int (*cru_fn)(uint64_t, void*, size_t);
typedef struct { pid_t pid; uid_t uid; char comm[17]; uint64_t cid, fp; int readable, exact; } E;
int main(void){ cru_fn cru=(cru_fn)dlsym(RTLD_DEFAULT,"coalition_info_resource_usage");
  uint64_t t0=mach_absolute_time();
  int n=proc_listallpids(NULL,0); pid_t *p=calloc(n+64,4); n=proc_listallpids(p,(n+64)*4); E *e=calloc(n,sizeof(E));
  for(int i=0;i<n;i++){ e[i].pid=p[i]; struct proc_bsdshortinfo s; if(proc_pidinfo(p[i],PROC_PIDT_SHORTBSDINFO,0,&s,sizeof s)==sizeof s){ e[i].uid=s.pbsi_uid; memcpy(e[i].comm,s.pbsi_comm,16);} 
    struct pidcoal q={0}; if(proc_pidinfo(p[i],20,0,&q,sizeof q)==sizeof q) e[i].cid=q.coalition_id[0];
    struct rusage_info_v6 ru; if(proc_pid_rusage(p[i],RUSAGE_INFO_V6,(rusage_info_t*)&ru)==0){ e[i].fp=ru.ri_phys_footprint; e[i].readable=1; e[i].exact=1; } }
  int ncall=0, exact_foreign=0, group_only=0, foreign=0;
  for(int i=0;i<n;i++){ if(e[i].readable||!e[i].cid) continue; foreign++;
    int unread=0; uint64_t readsum=0; for(int j=0;j<n;j++) if(e[j].cid==e[i].cid){ if(e[j].readable) readsum+=e[j].fp; else unread++; }
    uint64_t u[64]={0}; ncall++; if(cru(e[i].cid,u,sizeof u)) continue;
    if(unread==1){ e[i].fp=u[40]>readsum?u[40]-readsum:0; e[i].exact=1; exact_foreign++; } else group_only++; }
  uint64_t t1=mach_absolute_time(); mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  printf("pids=%d foreign=%d: exact footprint via coalition=%d, only as a coalition group total=%d; coalition calls=%d; full scan %.1f ms\n",n,foreign,exact_foreign,group_only,ncall,(t1-t0)*tb.numer/tb.denom/1e6);
  printf("group-only foreign examples:"); int k=0; for(int i=0;i<n&&k<14;i++) if(!e[i].readable&&!e[i].exact&&e[i].cid){ printf(" %d:%s(coal %llu)",e[i].pid,e[i].comm,e[i].cid); k++; } printf("\n");
  printf("largest exact foreign footprints:\n"); for(int r=0;r<8;r++){ int b=-1; for(int i=0;i<n;i++) if(!e[i].readable&&e[i].exact&&(b<0||e[i].fp>e[b].fp)) b=i; if(b<0)break; printf("  pid %-6d uid %-4d %-16s %.1f MiB\n",e[b].pid,e[b].uid,e[b].comm,e[b].fp/1048576.0); e[b].exact=2; e[b].readable=1; }
  return 0; }
