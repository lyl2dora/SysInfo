// Try alternate call paths for HOST_CPU_COUNTERS_INFO / PROCESSOR_CPU_COUNTERS_INFO (read-only).
#include <stdio.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/host_info.h>
int main(void) {
    host_cpu_counters_info_data_t h = {0};
    mach_msg_type_number_t cnt;
    kern_return_t kr;
    cnt = HOST_CPU_COUNTERS_INFO_COUNT;
    kr = host_statistics(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info_t)&h, &cnt);
    printf("host_statistics(8): kr=%d %s cnt=%u energy=%llu\n", kr, mach_error_string(kr), cnt, h.energy_nj);
    cnt = HOST_CPU_COUNTERS_INFO_COUNT;
    kr = host_info(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info_t)&h, &cnt);
    printf("host_info(8): kr=%d %s cnt=%u energy=%llu\n", kr, mach_error_string(kr), cnt, h.energy_nj);
    for (int c = 1; c <= 12; c++) { cnt = c; kr = host_statistics64(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info64_t)&h, &cnt); if (kr == 0) { printf("host_statistics64(8) ok with cnt=%d\n", c); break; } }
    printf("host_statistics64(8) last kr=%d %s\n", kr, mach_error_string(kr));
    // per-processor via processor ports (host_processors needs host_priv; try anyway)
    processor_array_t procs; mach_msg_type_number_t np;
    kr = host_processors(mach_host_self(), &procs, &np);
    printf("host_processors(host_self): kr=%d %s\n", kr, mach_error_string(kr));
    // sanity: existing flavor
    natural_t n; processor_info_array_t a; mach_msg_type_number_t ac;
    kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &a, &ac);
    printf("host_processor_info(PROCESSOR_CPU_LOAD_INFO) sanity: kr=%d ncpu=%u\n", kr, n);
    kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_COUNTERS_INFO, &n, &a, &ac);
    printf("host_processor_info(PROCESSOR_CPU_COUNTERS_INFO): kr=%d %s\n", kr, mach_error_string(kr));
    return 0;
}
