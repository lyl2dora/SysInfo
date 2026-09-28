// coalition_probe.c - can a normal user group FOREIGN processes (root / _windowserver / _coreaudiod ...) by coalition,
// and read coalition resource usage for them? Two samples 2 s apart to show counters advance. Read-only.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <mach/mach_time.h>
struct pidcoal { uint64_t coalition_id[2]; uint64_t r1,r2,r3; };
typedef int (*cru_fn)(uint64_t, void*, size_t);
static cru_fn cru;
static pid_t findcomm(const char*c){ int n=proc_listallpids(NULL,0); pid_t *p=calloc(n+64,4); n=proc_listallpids(p,(n+64)*4);
  for(int i=0;i<n;i++){ struct proc_bsdshortinfo s; if(proc_pidinfo(p[i],PROC_PIDT_SHORTBSDINFO,0,&s,sizeof s)==sizeof s && !strcmp(s.pbsi_comm,c)){ pid_t r=p[i]; free(p); return r;} } free(p); return -1; }
int main(void){
  cru=(cru_fn)dlsym(RTLD_DEFAULT,"coalition_info_resource_usage");
  const char *names[]={"WindowServer","coreaudiod","mds","syspolicyd","kernel_task","launchd",NULL};
  // 1) coalition ids of foreign processes, and which other pids share the jetsam coalition (grouping)
  int n=proc_listallpids(NULL,0); pid_t *all=calloc(n+64,4); n=proc_listallpids(all,(n+64)*4);
  for(int k=0;names[k];k++){ pid_t pid=findcomm(names[k]); if(pid<0){ printf("%s: not found\n",names[k]); continue; }
    struct proc_bsdshortinfo s; proc_pidinfo(pid,PROC_PIDT_SHORTBSDINFO,0,&s,sizeof s);
    struct pidcoal pc={0}; errno=0; int r=proc_pidinfo(pid,20,0,&pc,sizeof pc);
    printf("%-13s pid=%-6d uid=%-4d PIDCOALITIONINFO rc=%d errno=%d resource_coal=%llu jetsam_coal=%llu  members(jetsam):",names[k],pid,s.pbsi_uid,r,r>0?0:errno,pc.coalition_id[0],pc.coalition_id[1]);
    int m=0; for(int i=0;i<n&&m<8;i++){ struct pidcoal q={0}; if(all[i]!=pid && proc_pidinfo(all[i],20,0,&q,sizeof q)==sizeof q && q.coalition_id[1]==pc.coalition_id[1] && pc.coalition_id[1]){ struct proc_bsdshortinfo t; proc_pidinfo(all[i],PROC_PIDT_SHORTBSDINFO,0,&t,sizeof t); printf(" %d:%s(uid%d)",all[i],t.pbsi_comm,t.pbsi_uid); m++; } }
    printf("\n"); }
  // 2) resource usage for WindowServer's coalition: two samples, show which u64 slots move
  pid_t ws=findcomm("WindowServer"); struct pidcoal pc={0}; proc_pidinfo(ws,20,0,&pc,sizeof pc);
  uint64_t a[128]={0}, b[128]={0}; errno=0; int r1=cru(pc.coalition_id[0],a,sizeof a); int e1=errno; sleep(2); int r2=cru(pc.coalition_id[0],b,sizeof b);
  int last=0; for(int i=0;i<128;i++) if(a[i]||b[i]) last=i;
  printf("\nWindowServer resource coalition %llu: rc=%d/%d errno=%d; last non-zero u64 index=%d\n",pc.coalition_id[0],r1,r2,e1,last);
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  for(int i=0;i<=last;i++) printf("  u64[%2d] = %20llu  delta(2s) = %llu\n",i,a[i],b[i]-a[i]);
  printf("timebase %u/%u (if slot 3 is cpu_time in mach ticks: %.3f CPU-s over 2 s)\n",tb.numer,tb.denom,(b[3]-a[3])*(double)tb.numer/tb.denom/1e9);
  return 0; }
