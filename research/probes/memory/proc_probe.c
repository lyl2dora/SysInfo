// proc_probe.c - per-process memory as a normal user: proc_pid_rusage (phys_footprint) vs PROC_PIDTASKINFO (resident)
// tallies success/failure by owner (self uid / root / other uid) and prints top-N by footprint.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pwd.h>

typedef struct { pid_t pid; uid_t uid; char name[64]; char path[PROC_PIDPATHINFO_MAXSIZE];
  int ru_rc, ru_err, ti_rc, ti_err, bsd_rc, bsd_err, sbsd_rc, sbsd_err, path_rc, path_err, tn_kr, tvm_kr;
  struct rusage_info_v6 ru; struct proc_taskinfo ti; uint64_t tvm_footprint; } P;

static int cmp(const void*a,const void*b){ const P*x=a,*y=b; uint64_t fx=x->ru_rc==0?x->ru.ri_phys_footprint:0, fy=y->ru_rc==0?y->ru.ri_phys_footprint:0; return fx<fy?1:fx>fy?-1:0; }
static double MiB(uint64_t b){ return b/1048576.0; }

int main(int argc, char**argv){
  int topn = argc>1?atoi(argv[1]):20;
  uid_t me = getuid();
  uint64_t t0 = mach_absolute_time();
  int n = proc_listallpids(NULL, 0);
  pid_t *pids = calloc(n+64, sizeof(pid_t));
  n = proc_listallpids(pids, (n+64)*sizeof(pid_t));
  P *ps = calloc(n, sizeof(P));
  int cnt[3][6]={{0}}; // [owner: 0 self,1 root,2 other][0 total,1 rusage ok,2 taskinfo ok,3 bsdinfo ok,4 shortbsd ok,5 path ok]
  for (int i=0;i<n;i++){
    P *p=&ps[i]; p->pid=pids[i];
    // uid via sysctl KERN_PROC_PID (works for all processes)
    struct kinfo_proc kp; size_t len=sizeof kp; int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,p->pid};
    if (sysctl(mib,4,&kp,&len,NULL,0)==0 && len>0) { p->uid=kp.kp_eproc.e_ucred.cr_uid; strncpy(p->name,kp.kp_proc.p_comm,sizeof p->name-1);} else p->uid=(uid_t)-1;
    errno=0; p->ru_rc = proc_pid_rusage(p->pid, RUSAGE_INFO_V6, (rusage_info_t*)&p->ru); p->ru_err=p->ru_rc?errno:0;
    errno=0; int r = proc_pidinfo(p->pid, PROC_PIDTASKINFO, 0, &p->ti, sizeof p->ti); p->ti_rc = (r==sizeof p->ti)?0:-1; p->ti_err=p->ti_rc?errno:0;
    struct proc_bsdinfo bi; errno=0; r=proc_pidinfo(p->pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi); p->bsd_rc=(r==sizeof bi)?0:-1; p->bsd_err=p->bsd_rc?errno:0;
    struct proc_bsdshortinfo sbi; errno=0; r=proc_pidinfo(p->pid, PROC_PIDT_SHORTBSDINFO, 0, &sbi, sizeof sbi); p->sbsd_rc=(r==sizeof sbi)?0:-1; p->sbsd_err=p->sbsd_rc?errno:0;
    if (!p->sbsd_rc) strncpy(p->name, sbi.pbsi_comm, sizeof p->name-1);
    errno=0; r=proc_pidpath(p->pid, p->path, sizeof p->path); p->path_rc=r>0?0:-1; p->path_err=p->path_rc?errno:0;
    // task_name_for_pid + TASK_VM_INFO
    mach_port_t tn=MACH_PORT_NULL; p->tn_kr = task_name_for_pid(mach_task_self(), p->pid, &tn); p->tvm_kr=-1;
    if (p->tn_kr==KERN_SUCCESS){ task_vm_info_data_t v; mach_msg_type_number_t c=TASK_VM_INFO_COUNT; p->tvm_kr=task_info(tn,TASK_VM_INFO,(task_info_t)&v,&c); if(!p->tvm_kr) p->tvm_footprint=v.phys_footprint; mach_port_deallocate(mach_task_self(),tn);} 
    int o = p->uid==me?0:(p->uid==0?1:2);
    cnt[o][0]++; if(!p->ru_rc)cnt[o][1]++; if(!p->ti_rc)cnt[o][2]++; if(!p->bsd_rc)cnt[o][3]++; if(!p->sbsd_rc)cnt[o][4]++; if(!p->path_rc)cnt[o][5]++;
  }
  uint64_t t1 = mach_absolute_time(); mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  printf("uid=%d  proc_listallpids -> %d pids; full scan (6 calls/pid) took %.1f ms\n", me, n, (t1-t0)*tb.numer/tb.denom/1e6);
  const char *on[3]={"self uid","root","other uid"};
  printf("%-10s %6s %10s %12s %10s %13s %9s\n","owner","total","rusage_ok","taskinfo_ok","bsdinfo_ok","shortbsd_ok","path_ok");
  for(int o=0;o<3;o++) printf("%-10s %6d %10d %12d %10d %13d %9d\n",on[o],cnt[o][0],cnt[o][1],cnt[o][2],cnt[o][3],cnt[o][4],cnt[o][5]);
  // errno histogram for failures
  int e_ru[128]={0}, e_ti[128]={0}, tnok[3]={0}, tvmok[3]={0};
  for(int i=0;i<n;i++){ P*p=&ps[i]; if(p->ru_rc && p->ru_err<128) e_ru[p->ru_err]++; if(p->ti_rc && p->ti_err<128) e_ti[p->ti_err]++; int o=p->uid==me?0:(p->uid==0?1:2); if(p->tn_kr==0) tnok[o]++; if(p->tvm_kr==0) tvmok[o]++; }
  for(int e=0;e<128;e++){ if(e_ru[e]) printf("proc_pid_rusage failures errno=%d (%s): %d\n",e,strerror(e),e_ru[e]); if(e_ti[e]) printf("PROC_PIDTASKINFO failures errno=%d (%s): %d\n",e,strerror(e),e_ti[e]); }
  printf("task_name_for_pid ok: self=%d root=%d other=%d ; task_info(TASK_VM_INFO) on name port ok: self=%d root=%d other=%d\n",tnok[0],tnok[1],tnok[2],tvmok[0],tvmok[1],tvmok[2]);
  // list other-uid processes
  printf("other-uid processes (sample): "); int k=0; for(int i=0;i<n&&k<12;i++) if(ps[i].uid!=me && ps[i].uid!=0){ struct passwd*pw=getpwuid(ps[i].uid); printf("%d:%s(%s) ",ps[i].pid,ps[i].name,pw?pw->pw_name:"?"); k++;} printf("\n");
  qsort(ps,n,sizeof(P),cmp);
  printf("\nTop %d by ri_phys_footprint (only readable ones):\n%-7s %-24s %-6s %12s %12s %12s %12s %10s %10s %10s\n",topn,"pid","name","uid","footprintMiB","residentMiB(ru)","residentMiB(ti)","tvmFootMiB","neuralMiB","lifemaxMiB","pgcachehit");
  for(int i=0;i<n&&i<topn;i++){ P*p=&ps[i]; if(p->ru_rc) continue;
    printf("%-7d %-24.24s %-6d %12.1f %12.1f %12.1f %12.1f %10.1f %10.1f %10llu\n",p->pid,p->name,p->uid,MiB(p->ru.ri_phys_footprint),MiB(p->ru.ri_resident_size),p->ti_rc?-1.0:MiB(p->ti.pti_resident_size),p->tvm_kr?-1.0:MiB(p->tvm_footprint),MiB(p->ru.ri_neural_footprint),MiB(p->ru.ri_lifetime_max_phys_footprint),p->ru.ri_page_cache_hits);
  }
  uint64_t sumfp=0, sumrs=0; int nz_neural=0, nz_conclave=0, nz_pwait=0, nz_pch=0; for(int i=0;i<n;i++) if(!ps[i].ru_rc){ sumfp+=ps[i].ru.ri_phys_footprint; sumrs+=ps[i].ru.ri_resident_size; if(ps[i].ru.ri_neural_footprint)nz_neural++; if(ps[i].ru.ri_conclave_footprint)nz_conclave++; if(ps[i].ru.ri_page_wait_time_mach)nz_pwait++; if(ps[i].ru.ri_page_cache_hits)nz_pch++; }
  printf("\nsum over readable procs: footprint=%.2f GiB resident=%.2f GiB ; nonzero ri_neural_footprint=%d ri_conclave_footprint=%d ri_page_wait_time_mach=%d ri_page_cache_hits=%d\n", sumfp/1073741824.0, sumrs/1073741824.0, nz_neural, nz_conclave, nz_pwait, nz_pch);
  // root-owned examples that fail
  printf("root-owned failure examples: "); k=0; for(int i=0;i<n&&k<8;i++) if(ps[i].uid==0 && ps[i].ru_rc){ printf("%d:%s(ru errno=%d ti errno=%d path_ok=%d) ",ps[i].pid,ps[i].name,ps[i].ru_err,ps[i].ti_err,!ps[i].path_rc); k++;} printf("\n");
  printf("self-uid failure examples: "); k=0; for(int i=0;i<n&&k<8;i++) if(ps[i].uid==me && ps[i].ru_rc){ printf("%d:%s(ru errno=%d) ",ps[i].pid,ps[i].name,ps[i].ru_err); k++;} printf("\n");
  return 0;
}
