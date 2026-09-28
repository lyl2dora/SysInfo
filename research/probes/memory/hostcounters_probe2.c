// hostcounters_probe2.c - retry HOST_CPU_COUNTERS_INFO via host_statistics / host_info and varied counts
#include <stdio.h>
#include <mach/mach.h>
int main(void){
  uint64_t buf[32]; mach_msg_type_number_t c;
  unsigned counts[]={HOST_CPU_COUNTERS_INFO_COUNT,16,24,64};
  for(int i=0;i<4;i++){ c=counts[i]; kern_return_t k=host_statistics64(mach_host_self(),HOST_CPU_COUNTERS_INFO,(host_info64_t)buf,&c); printf("host_statistics64 count_in=%u -> kr=%d count_out=%u\n",counts[i],k,c); }
  c=HOST_CPU_COUNTERS_INFO_COUNT; kern_return_t k=host_statistics(mach_host_self(),HOST_CPU_COUNTERS_INFO,(host_info_t)buf,&c); printf("host_statistics -> kr=%d\n",k);
  c=HOST_CPU_COUNTERS_INFO_COUNT; k=host_info(mach_host_self(),HOST_CPU_COUNTERS_INFO,(host_info_t)buf,&c); printf("host_info -> kr=%d\n",k);
  return 0;
}
