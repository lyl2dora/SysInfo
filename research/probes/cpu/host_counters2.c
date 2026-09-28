// Probe: HOST_CPU_COUNTERS_INFO via host_statistics64/host_statistics/host_info with various counts
#include <stdio.h>
#include <mach/mach.h>
int main(){
  integer_t buf[256]; mach_msg_type_number_t counts[] = {12, 13, 16, 24, 64, 256};
  for(int i=0;i<6;i++){ mach_msg_type_number_t c=counts[i];
    kern_return_t k1 = host_statistics64(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info64_t)buf, &c); mach_msg_type_number_t c1=c; c=counts[i];
    kern_return_t k2 = host_statistics(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info_t)buf, &c); mach_msg_type_number_t c2=c; c=counts[i];
    kern_return_t k3 = host_info(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info_t)buf, &c);
    printf("count=%u: host_statistics64 kr=%d(%s)->%u  host_statistics kr=%d(%s)->%u  host_info kr=%d(%s)->%u\n", counts[i], k1, mach_error_string(k1), c1, k2, mach_error_string(k2), c2, k3, mach_error_string(k3), c);
  }
  return 0;
}
