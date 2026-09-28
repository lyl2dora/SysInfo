// vmstat_probe.c - host_statistics64(HOST_VM_INFO64) full dump + Stats vs Activity Monitor formulas
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <sys/sysctl.h>
#include <stddef.h>

#define GB(x) ((double)(x)/1073741824.0)
static void dump(const vm_statistics64_data_t *s, double ps) {
#define P(f) printf("  %-40s %20llu  (%9.3f GiB)\n", #f, (unsigned long long)s->f, GB((double)s->f*ps))
#define C(f) printf("  %-40s %20llu\n", #f, (unsigned long long)s->f)
  P(free_count); P(active_count); P(inactive_count); P(wire_count);
  C(zero_fill_count); C(reactivations); C(pageins); C(pageouts); C(faults); C(cow_faults); C(lookups); C(hits); C(purges);
  P(purgeable_count); P(speculative_count);
  C(decompressions); C(compressions); C(swapins); C(swapouts);
  P(compressor_page_count); P(throttled_count); P(external_page_count); P(internal_page_count);
  P(total_uncompressed_pages_in_compressor);
  P(swapped_count);
  P(total_tag_storage_pages); P(nontag_pageable_tag_storage_pages); P(nontag_wired_tag_storage_pages);
  P(free_tag_storage_pages); P(tag_storing_tag_storage_pages); P(total_tagged_pages); P(resident_tagged_pages);
  P(compressed_tagged_pages); C(tagged_compressions); C(tagged_decompressions); C(compressed_tag_storage_bytes);
  C(speculative_pages_created); C(speculative_pages_activated);
  P(swap_count);
  P(empty_tag_storing_tag_storage_pages); P(executable_count); P(shared_region_count); P(boot_stolen_count);
  P(secluded_count); P(active_internal_count); P(inactive_internal_count); P(active_external_count);
  P(inactive_external_count); P(purgeable_pageable_count); P(purgeable_wired_count); P(background_internal_count);
  P(background_external_count); P(donated_count); P(realtime_count); P(max_mem_count);
  C(phantom_ghosts_found); C(phantom_ghosts_added);
}

int main(void) {
  host_basic_info_data_t bi; mach_msg_type_number_t bc = HOST_BASIC_INFO_COUNT;
  kern_return_t kr = host_info(mach_host_self(), HOST_BASIC_INFO, (host_info_t)&bi, &bc);
  printf("host_info(HOST_BASIC_INFO) kr=%d max_mem=%llu (%.3f GiB) cpus=%d/%d\n", kr, bi.max_mem, GB(bi.max_mem), bi.avail_cpus, bi.max_cpus);
  uint64_t memsize=0, usable=0; size_t sz=8;
  sysctlbyname("hw.memsize", &memsize, &sz, NULL, 0); sz=8;
  int r = sysctlbyname("hw.memsize_usable", &usable, &sz, NULL, 0);
  printf("hw.memsize=%llu (%.3f GiB) hw.memsize_usable=%llu (%.3f GiB) rc=%d\n", memsize, GB(memsize), usable, GB(usable), r);
  vm_size_t hps=0; host_page_size(mach_host_self(), &hps);
  printf("vm_page_size=%lu vm_kernel_page_size=%lu host_page_size=%lu\n", (unsigned long)vm_page_size, (unsigned long)vm_kernel_page_size, (unsigned long)hps);

  printf("SDK counts: REV0=%u REV1=%u REV2=%u REV3=%u REV4=%u REV5=%u LATEST(REV6)=%u  sizeof(vm_statistics64)=%zu\n",
    HOST_VM_INFO64_REV0_COUNT, HOST_VM_INFO64_REV1_COUNT, HOST_VM_INFO64_REV2_COUNT, HOST_VM_INFO64_REV3_COUNT,
    HOST_VM_INFO64_REV4_COUNT, HOST_VM_INFO64_REV5_COUNT, HOST_VM_INFO64_LATEST_COUNT, sizeof(vm_statistics64_data_t));

  vm_statistics64_data_t s; memset(&s, 0xAB, sizeof s);
  mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
  kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&s, &cnt);
  printf("host_statistics64 kr=%d (%s) requested=%u returned count=%u (-> kernel fills rev with count %u)\n", kr, mach_error_string(kr), HOST_VM_INFO64_COUNT, cnt, cnt);
  if (kr) return 1;
  double ps = (double)vm_kernel_page_size;
  dump(&s, ps);

  double total = (double)bi.max_mem;
  // Stats formula (Modules/RAM/readers.swift:48-59,86-87)
  double active=s.active_count*ps, spec=s.speculative_count*ps, inact=s.inactive_count*ps, wired=s.wire_count*ps,
         compr=s.compressor_page_count*ps, purg=s.purgeable_count*ps, ext=s.external_page_count*ps, intl=s.internal_page_count*ps;
  double st_used = active+inact+spec+wired+compr-purg-ext;
  printf("\n== Stats formula ==\n used=%.3f GiB free=%.3f app=%.3f wired=%.3f compressed=%.3f cache=%.3f usage=%.1f%%\n",
    GB(st_used), GB(total-st_used), GB(st_used-wired-compr), GB(wired), GB(compr), GB(purg+ext), 100*st_used/total);
  // Activity Monitor style
  double am_app = intl - purg;
  double am_used = am_app + wired + compr;
  printf("== Activity-Monitor-style (app=internal-purgeable, cached=external+purgeable) ==\n used=%.3f GiB app=%.3f wired=%.3f compressed=%.3f cached=%.3f free(free_count)=%.3f usage=%.1f%%\n",
    GB(am_used), GB(am_app), GB(wired), GB(compr), GB(ext+purg), GB(s.free_count*ps), 100*am_used/total);
  printf(" diff (Stats - AM) used = %.3f GiB ; active+inactive+spec = %.3f GiB vs internal+external = %.3f GiB ; throttled=%.3f\n",
    GB(st_used-am_used), GB(active+inact+spec), GB(intl+ext), GB(s.throttled_count*ps));
  printf(" sum(free+active+inactive+wired+compressor+throttled+speculative?) = %.3f GiB vs max_mem %.3f (spec counted in free per header)\n",
    GB((s.free_count+s.active_count+s.inactive_count+s.wire_count+s.compressor_page_count+s.throttled_count)*ps), GB(total));
  if (s.compressor_page_count)
    printf(" compression ratio = uncompressed_in_compressor/compressor_page_count = %.2f : 1 (%.3f GiB -> %.3f GiB)\n",
      (double)s.total_uncompressed_pages_in_compressor/s.compressor_page_count, GB(s.total_uncompressed_pages_in_compressor*ps), GB(compr));

  // rate limiting check: 50 rapid calls
  vm_statistics64_data_t prev = s; int same=0, calls=50;
  for (int i=0;i<calls;i++) {
    vm_statistics64_data_t t; mach_msg_type_number_t c2 = HOST_VM_INFO64_COUNT;
    host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&t, &c2);
    if (memcmp(&t,&prev,sizeof t)==0) same++;
    prev=t; usleep(20000);
  }
  printf("\nrate-limit test: %d rapid calls (20ms apart, ~1s): %d returned byte-identical struct to previous call\n", calls, same);
  // slow sample for deltas
  sleep(2);
  vm_statistics64_data_t s2; cnt = HOST_VM_INFO64_COUNT;
  host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&s2, &cnt);
  printf("deltas over ~3s: faults +%llu zero_fill +%llu pageins +%llu pageouts +%llu compressions +%llu decompressions +%llu swapins +%llu swapouts +%llu purges +%llu reactivations +%llu\n",
    s2.faults-s.faults, s2.zero_fill_count-s.zero_fill_count, s2.pageins-s.pageins, s2.pageouts-s.pageouts, s2.compressions-s.compressions,
    s2.decompressions-s.decompressions, s2.swapins-s.swapins, s2.swapouts-s.swapouts, s2.purges-s.purges, s2.reactivations-s.reactivations);
  return 0;
}
