// rl_count_probe.c - when host_statistics64(HOST_VM_INFO64) is rate-limited (cached), what count / which fields come back?
// Buffer is pre-filled with 0xAB each call; a cached reply that only copies a prefix leaves 0xABAB... in the tail.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <stddef.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
int main(int argc, char **argv){
  int n = argc>1?atoi(argv[1]):40, gap_us = argc>2?atoi(argv[2]):5000;
  vm_statistics64_data_t prev; memset(&prev,0,sizeof prev);
  int hist[200]={0}; int tail_untouched=0, same_as_prev=0;
  for(int i=0;i<n;i++){
    vm_statistics64_data_t s; memset(&s,0xAB,sizeof s);
    mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    kern_return_t kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&s, &c);
    int untouched = (s.max_mem_count == 0xABABABABABABABABULL);
    int same = (s.faults==prev.faults && s.zero_fill_count==prev.zero_fill_count && s.free_count==prev.free_count);
    if (c<200) hist[c]++;
    tail_untouched += untouched; same_as_prev += (i>0 && same);
    if (i<25 || untouched) printf("call %2d kr=%d count=%u faults=%llu free=%u swapped_count=0x%llx total_tag_storage_pages=0x%llx boot_stolen=0x%llx max_mem_count=0x%llx %s%s\n",
      i,kr,c,s.faults,s.free_count,(unsigned long long)s.swapped_count,(unsigned long long)s.total_tag_storage_pages,(unsigned long long)s.boot_stolen_count,(unsigned long long)s.max_mem_count,
      same&&i?"[SAME-AS-PREV] ":"", untouched?"[TAIL-UNTOUCHED]":"");
    prev = s; usleep(gap_us);
  }
  printf("\nsummary: %d calls @%dus: returned-count histogram:", n, gap_us);
  for(int k=0;k<200;k++) if(hist[k]) printf(" count=%d x%d;",k,hist[k]);
  printf(" tail(max_mem_count) untouched in %d calls; identical-to-previous in %d calls\n", tail_untouched, same_as_prev);
  printf("offsets (ints): swapped_count=%zu total_tag_storage_pages=%zu swap_count=%zu boot_stolen=%zu max_mem_count=%zu\n",
    offsetof(vm_statistics64_data_t,swapped_count)/4, offsetof(vm_statistics64_data_t,total_tag_storage_pages)/4, offsetof(vm_statistics64_data_t,swap_count)/4,
    offsetof(vm_statistics64_data_t,boot_stolen_count)/4, offsetof(vm_statistics64_data_t,max_mem_count)/4);
  return 0;
}
