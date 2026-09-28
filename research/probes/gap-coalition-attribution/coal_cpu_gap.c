// coal_cpu_gap.c - why lifetime slot3 cpu_time < top TIME for some daemons: print slots 3,9,10,24..30 (eqos) and
// same-uid rusage user+sys for comparison. build: xcrun clang -O1 -o coal_cpu_gap coal_cpu_gap.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
typedef int (*cru_fn)(uint64_t, void *, size_t); typedef int (*pl_fn)(uint64_t, void *, size_t *); typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
int main(void) {
  cru_fn cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl_fn pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc_fn lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double t2n = (double)tb.numer / tb.denom / 1e9;
  int bytes = lc(2, 0, NULL, 0); struct coalinfo *ci = malloc(bytes + 8192); bytes = lc(2, 0, ci, bytes + 8192); int nc = bytes / sizeof *ci; int shown = 0;
  for (int i = 0; i < nc && shown < 25; i++) { pid_t p[8]; size_t sz = sizeof p; if (pl(ci[i].cid, p, &sz) || sz != sizeof(pid_t)) continue;
    uint64_t s[50]; cru(ci[i].cid, s, sizeof s); if (s[0] > 2) continue;
    struct rusage_info_v6 r; if (proc_pid_rusage(p[0], RUSAGE_INFO_V6, (rusage_info_t *)&r)) continue;
    double rt = (r.ri_user_time + r.ri_system_time) * t2n, c3 = s[3] * t2n; if (rt < 5 || c3 / rt > 0.98) continue;
    uint64_t eq = 0; for (int k = 24; k <= 30; k++) eq += s[k];
    char nm[64]; proc_name(p[0], nm, sizeof nm); shown++;
    printf("%-20.20s rusage user+sys=%.2f s  slot3=%.2f s (%.1f%%)  sum(eqos)=%.2f s  billed_to_me(9)=%.2f s  billed_to_others(10)=%.2f s  slot3+10=%.2f s  ri_billed_sys=%.2f ri_serviced_sys=%.2f\n",
      nm, rt, c3, 100 * c3 / rt, eq * t2n, s[9] * t2n, s[10] * t2n, (s[3] + s[10]) * t2n, r.ri_billed_system_time * t2n, r.ri_serviced_system_time * t2n); }
  return 0; }
