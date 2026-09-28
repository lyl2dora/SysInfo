// taskvm_probe.c - per-process compressed/footprint via task_name_for_pid + task_info(TASK_VM_INFO) (same-uid only),
// (userland struct vmspace in kinfo_proc is an opaque dummy: KERN_PROC exposes no memory figures).
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <libproc.h>
#include <sys/sysctl.h>
int main(int argc,char**argv){
  int pids[]={859,664,1017,465,172,1,0};
  for(int i=0;pids[i]||i==6;i++){ int p=pids[i]; char nm[64]={0}; struct proc_bsdshortinfo s; if(proc_pidinfo(p,PROC_PIDT_SHORTBSDINFO,0,&s,sizeof s)>0) snprintf(nm,64,"%s",s.pbsi_comm);
    mach_port_t tn; kern_return_t kr=task_name_for_pid(mach_task_self(),p,&tn);
    struct kinfo_proc kp; size_t l=sizeof kp; int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,p}; sysctl(mib,4,&kp,&l,NULL,0);
    if(kr==KERN_SUCCESS){ task_vm_info_data_t v; mach_msg_type_number_t c=TASK_VM_INFO_COUNT; kern_return_t k2=task_info(tn,TASK_VM_INFO,(task_info_t)&v,&c);
      printf("pid %d %-18s task_name_for_pid ok; TASK_VM_INFO kr=%d footprint=%.1fMiB compressed=%.1fMiB internal=%.1fMiB resident=%.1fMiB ledger_tag_neural_footprint? n/a\n",
        p,nm,k2,v.phys_footprint/1048576.0,v.compressed/1048576.0,v.internal/1048576.0,v.resident_size/1048576.0);
      mach_port_deallocate(mach_task_self(),tn);
    } else printf("pid %d %-18s task_name_for_pid kr=%d (%s)\n",p,nm,kr,mach_error_string(kr));
    if(i==6) break; }
  return 0;
}
