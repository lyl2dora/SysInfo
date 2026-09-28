// Probe macOS 27 new Mach flavors: HOST_CPU_COUNTERS_INFO (host_statistics64)
// and PROCESSOR_CPU_COUNTERS_INFO (host_processor_info). Also new
// vm_statistics64 rev6 fields and rusage_info ri_page_wait_time_mach.
// Read-only, unprivileged. Two samples 1 s apart to check counters advance.
#include <stdio.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/host_info.h>
#include <mach/vm_statistics.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <sys/resource.h>

static double ns_per_tick(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    return (double)tb.numer / tb.denom;
}

static int host_sample(host_cpu_counters_info_data_t *o) {
    mach_msg_type_number_t cnt = HOST_CPU_COUNTERS_INFO_COUNT;
    kern_return_t kr = host_statistics64(mach_host_self(), HOST_CPU_COUNTERS_INFO, (host_info64_t)o, &cnt);
    if (kr != KERN_SUCCESS) { printf("host_statistics64(HOST_CPU_COUNTERS_INFO) kr=%d (%s)\n", kr, mach_error_string(kr)); return -1; }
    return (int)cnt;
}

typedef struct { natural_t n; processor_cpu_counters_info_data_t *d; mach_msg_type_number_t cnt; } per_cpu_t;

static int cpu_sample(per_cpu_t *s) {
    processor_info_array_t arr = NULL;
    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_COUNTERS_INFO, &s->n, &arr, &s->cnt);
    if (kr != KERN_SUCCESS) { printf("host_processor_info(PROCESSOR_CPU_COUNTERS_INFO) kr=%d (%s)\n", kr, mach_error_string(kr)); return -1; }
    s->d = (processor_cpu_counters_info_data_t *)arr;
    return 0;
}

int main(void) {
    double k = ns_per_tick();
    printf("timebase ns/tick=%.4f  HOST_CPU_COUNTERS_INFO_COUNT=%u  PROCESSOR_CPU_COUNTERS_INFO_COUNT=%u\n",
           k, (unsigned)HOST_CPU_COUNTERS_INFO_COUNT, (unsigned)PROCESSOR_CPU_COUNTERS_INFO_COUNT);

    host_cpu_counters_info_data_t h1 = {0}, h2 = {0};
    per_cpu_t c1 = {0}, c2 = {0};
    int hr1 = host_sample(&h1); int cr1 = cpu_sample(&c1);
    uint64_t t1 = mach_absolute_time();
    // light busy work for ~0.3s then sleep, so counters move
    volatile double x = 0; uint64_t st = mach_absolute_time();
    while ((mach_absolute_time() - st) * k < 3e8) x += 1.0;
    sleep(1);
    int hr2 = host_sample(&h2); int cr2 = cpu_sample(&c2);
    uint64_t t2 = mach_absolute_time();
    double wall_s = (t2 - t1) * k / 1e9;
    printf("wall=%.3fs\n", wall_s);

    if (hr1 >= 0 && hr2 >= 0) {
        printf("HOST s1: user=%llu sys=%llu idle=%llu cycles=%llu instr=%llu energy_nj=%llu (cnt=%d)\n",
               h1.user_time_mach, h1.system_time_mach, h1.idle_time_mach, h1.cycles, h1.instructions, h1.energy_nj, hr1);
        printf("HOST s2: user=%llu sys=%llu idle=%llu cycles=%llu instr=%llu energy_nj=%llu\n",
               h2.user_time_mach, h2.system_time_mach, h2.idle_time_mach, h2.cycles, h2.instructions, h2.energy_nj);
        double du = (h2.user_time_mach - h1.user_time_mach) * k / 1e9, ds = (h2.system_time_mach - h1.system_time_mach) * k / 1e9,
               di = (h2.idle_time_mach - h1.idle_time_mach) * k / 1e9;
        double dE = (double)(h2.energy_nj - h1.energy_nj) / 1e9;
        printf("HOST delta: user=%.3fs sys=%.3fs idle=%.3fs (sum=%.3f cpu-s over %.3f wall-s) cycles=%llu instr=%llu energy=%.4f J => avg CPU power %.3f W\n",
               du, ds, di, du + ds + di, wall_s, h2.cycles - h1.cycles, h2.instructions - h1.instructions, dE, dE / wall_s);
    }
    if (cr1 == 0 && cr2 == 0) {
        printf("PER-CPU: ncpu=%u cnt=%u\n", c2.n, c2.cnt);
        double totE = 0;
        for (natural_t i = 0; i < c2.n && i < c1.n; i++) {
            processor_cpu_counters_info_data_t *a = &c1.d[i], *b = &c2.d[i];
            double du = (b->user_time_mach - a->user_time_mach) * k / 1e9, ds = (b->system_time_mach - a->system_time_mach) * k / 1e9,
                   di = (b->idle_time_mach - a->idle_time_mach) * k / 1e9;
            double busy = du + ds, tot = du + ds + di;
            double dE = (double)(b->energy_nj - a->energy_nj) / 1e9; totE += dE;
            double cyc = (double)(b->cycles - a->cycles);
            double freq_active = busy > 0 ? cyc / busy / 1e6 : 0;
            printf(" cpu%-2u busy=%5.1f%% user=%.3f sys=%.3f idle=%.3f cycles=%llu instr=%llu E=%.4fJ P=%.3fW active-MHz~%.0f\n",
                   i, tot > 0 ? 100 * busy / tot : 0, du, ds, di, b->cycles - a->cycles, b->instructions - a->instructions, dE, dE / wall_s, freq_active);
        }
        printf("PER-CPU total energy %.4f J => %.3f W\n", totE, totE / wall_s);
    }

    // vm_statistics64 rev6
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t vcnt = HOST_VM_INFO64_COUNT;
    kern_return_t kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &vcnt);
    printf("HOST_VM_INFO64 kr=%d count=%u (REV6=%u) swap_count=%llu executable_count=%llu shared_region_count=%llu active_internal=%llu inactive_internal=%llu speculative_pages_created=%llu\n",
           kr, vcnt, (unsigned)HOST_VM_INFO64_REV6_COUNT, vm.swap_count, vm.executable_count, vm.shared_region_count,
           vm.active_internal_count, vm.inactive_internal_count, vm.speculative_pages_created);

    // rusage_info_v6 new fields for self
    struct rusage_info_v6 ri = {0};
    int r = proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ri);
    printf("proc_pid_rusage(self,V6) r=%d ri_page_wait_time_mach=%llu ri_page_cache_hits=%llu ri_conclave_footprint=%llu ri_energy_nj=%llu\n",
           r, ri.ri_page_wait_time_mach, ri.ri_page_cache_hits, ri.ri_conclave_footprint, ri.ri_energy_nj);
    return 0;
}
