// coal_vs_resp.c - for same-uid pids (where responsibility_get_pid_responsible_for_pid works), does grouping by
// JETSAM coalition id agree with grouping by responsible pid? (i.e. can coalition grouping stand in for foreign pids?)
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
struct pidcoal { uint64_t coalition_id[2]; uint64_t r1,r2,r3; };
typedef int (*resp_fn)(int);
int main(void){ resp_fn resp=(resp_fn)dlsym(RTLD_DEFAULT,"responsibility_get_pid_responsible_for_pid");
  int n=proc_listallpids(NULL,0); pid_t *p=calloc(n+64,4); n=proc_listallpids(p,(n+64)*4);
  int *r=calloc(n,4); uint64_t *jc=calloc(n,8), *rc=calloc(n,8);
  for(int i=0;i<n;i++){ r[i]=resp(p[i]); struct pidcoal q={0}; if(proc_pidinfo(p[i],20,0,&q,sizeof q)==sizeof q){ rc[i]=q.coalition_id[0]; jc[i]=q.coalition_id[1]; } }
  long pairs=0, agree_j=0, agree_r=0;
  for(int i=0;i<n;i++) for(int j=i+1;j<n;j++){ if(r[i]<0||r[j]<0) continue; pairs++; int sr=(r[i]==r[j]); if(sr==(jc[i]==jc[j])) agree_j++; if(sr==(rc[i]==rc[j])) agree_r++; }
  printf("same-uid pid pairs=%ld: 'same responsible pid' agrees with 'same jetsam coalition' in %.2f%% and with 'same resource coalition' in %.2f%% of pairs\n",pairs,100.0*agree_j/pairs,100.0*agree_r/pairs);
  return 0; }
