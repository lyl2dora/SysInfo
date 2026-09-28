// foreign_access_probe.c - full-scan re-check of name/responsibility APIs by owner, plus a probe of the private
// coalition resource-usage path (PROC_PIDCOALITIONINFO=20 + coalition_info_resource_usage) for foreign processes.
// Read-only: no signals, no writes.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>
struct pidcoal { uint64_t coalition_id[2]; uint64_t r1,r2,r3; };
typedef int (*cru_fn)(uint64_t, void*, size_t);
typedef int (*resp_fn)(int);
int main(void){
  uid_t me=getuid(); int n=proc_listallpids(NULL,0); pid_t *p=calloc(n+64,sizeof(pid_t)); n=proc_listallpids(p,(n+64)*sizeof(pid_t));
  resp_fn resp=(resp_fn)dlsym(RTLD_DEFAULT,"responsibility_get_pid_responsible_for_pid");
  cru_fn cru=(cru_fn)dlsym(RTLD_DEFAULT,"coalition_info_resource_usage");
  printf("pids=%d responsibility fn=%p coalition_info_resource_usage=%p\n",n,(void*)resp,(void*)cru);
  int tot[2]={0}, pn_ok[2]={0}, rs_ok[2]={0}, co_ok[2]={0}, cr_ok[2]={0}; int cr_err[2][128]={{0}}, co_err[2][128]={{0}};
  pid_t ex_foreign=-1; uint64_t ex_cid=0; unsigned char exbuf[1024];
  for(int i=0;i<n;i++){ struct proc_bsdshortinfo s; if(proc_pidinfo(p[i],PROC_PIDT_SHORTBSDINFO,0,&s,sizeof s)!=sizeof s) continue;
    int o = s.pbsi_uid==me?0:1; tot[o]++;
    char nm[256]={0}; errno=0; if(proc_name(p[i],nm,sizeof nm)>0 && nm[0]) pn_ok[o]++;
    if(resp && resp(p[i])!=-1) rs_ok[o]++;
    struct pidcoal pc; memset(&pc,0,sizeof pc); errno=0; int r=proc_pidinfo(p[i],20,0,&pc,sizeof pc);
    if(r==sizeof pc && pc.coalition_id[0]){ co_ok[o]++;
      unsigned char buf[1024]; memset(buf,0,sizeof buf); errno=0; int rr=cru?cru(pc.coalition_id[0],buf,sizeof buf):-2;
      if(rr==0){ cr_ok[o]++; if(o==1 && ex_foreign<0 && s.pbsi_uid==0){ ex_foreign=p[i]; ex_cid=pc.coalition_id[0]; memcpy(exbuf,buf,sizeof buf);} }
      else if(errno<128) cr_err[o][errno]++;
    } else if(errno<128) co_err[o][errno]++;
  }
  const char*on[2]={"self-uid","foreign(root+other)"};
  for(int o=0;o<2;o++){ printf("%-20s total=%d proc_name_ok=%d responsible_ok=%d PROC_PIDCOALITIONINFO_ok=%d coalition_resource_usage_ok=%d\n",on[o],tot[o],pn_ok[o],rs_ok[o],co_ok[o],cr_ok[o]);
    for(int e=0;e<128;e++){ if(co_err[o][e]) printf("   PIDCOALITIONINFO errno %d (%s) x%d\n",e,strerror(e),co_err[o][e]); if(cr_err[o][e]) printf("   coalition_info_resource_usage errno %d (%s) x%d\n",e,strerror(e),cr_err[o][e]); } }
  if(ex_foreign>0){ uint64_t *u=(uint64_t*)exbuf; char nm[64]={0}; struct proc_bsdshortinfo s; proc_pidinfo(ex_foreign,PROC_PIDT_SHORTBSDINFO,0,&s,sizeof s);
    printf("example root pid %d (%s) coalition %llu raw u64[0..11]:",ex_foreign,s.pbsi_comm,ex_cid); for(int k=0;k<12;k++) printf(" %llu",u[k]); printf("\n"); }
  return 0; }
