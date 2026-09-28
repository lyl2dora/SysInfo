#include <stdio.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
int main(void){
  uint64_t buf[64]; mach_msg_type_number_t c;
  int fl[]={4,6,7,8,9,10,99};
  for(unsigned i=0;i<sizeof fl/sizeof*fl;i++){
    memset(buf,0,sizeof buf); c=12;
    kern_return_t kr=host_statistics64(mach_host_self(),fl[i],(host_info64_t)buf,&c);
    printf("host_statistics64 flavor=%d count_in=12 -> kr=%d (%s) count_out=%u\n",fl[i],kr,mach_error_string(kr),c);
  }
  int pf[]={1,2,3,4,99,0x10000002};
  for(unsigned i=0;i<sizeof pf/sizeof*pf;i++){
    natural_t n=0; processor_info_array_t a=NULL; mach_msg_type_number_t cnt=0;
    kern_return_t kr=host_processor_info(mach_host_self(),pf[i],&n,&a,&cnt);
    printf("host_processor_info flavor=0x%x -> kr=%d (%s) ncpu=%u cnt=%u\n",pf[i],kr,mach_error_string(kr),n,cnt);
    if(kr==0) vm_deallocate(mach_task_self(),(vm_address_t)a,cnt*sizeof(integer_t));
  }
  return 0;
}
