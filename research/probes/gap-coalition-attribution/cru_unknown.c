// cru_unknown.c - eyeball the slots with no direct rusage match (12-15,33,44-48) next to candidate rusage fields for
// same-uid single-member coalitions. Read-only.  build: xcrun clang -O1 -o cru_unknown cru_unknown.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/resource.h>
typedef int (*cru_fn)(uint64_t, void *, size_t); typedef int (*pl_fn)(uint64_t, void *, size_t *); typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
int main(void) {
  cru_fn cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl_fn pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc_fn lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  int bytes = lc(2, 0, NULL, 0); struct coalinfo *ci = malloc(bytes + 4096); bytes = lc(2, 0, ci, bytes + 4096); int nc = bytes / sizeof *ci; int shown = 0;
  int n45 = 0, n45_le_runnable = 0; double r45sum = 0; int n46 = 0; int n48 = 0;
  for (int i = 0; i < nc; i++) {
    pid_t p[64]; size_t sz = sizeof p; if (pl(ci[i].cid, p, &sz) != 0 || sz != sizeof(pid_t)) continue;
    struct rusage_info_v6 r; if (proc_pid_rusage(p[0], RUSAGE_INFO_V6, (rusage_info_t *)&r) != 0) continue;
    uint64_t s[50]; if (cru(ci[i].cid, s, sizeof s)) continue; if (s[0] > 2) continue;
    char nm[64] = ""; proc_name(p[0], nm, sizeof nm);
    if (shown < 14 && (s[47] || shown < 8)) { shown++;
      printf("%-22.22s cid %-5llu | s12=%llu s13=%llu s14=%llu s15=%llu s33=%llu sum12..15=%llu ri_logical_writes=%llu\n", nm, ci[i].cid, s[12], s[13], s[14], s[15], s[33], s[12] + s[13] + s[14] + s[15], r.ri_logical_writes);
      printf("    s44=%llu s45=%llu s46=%llu s47=%llu s48=%llu s49=%llu | pageins=%llu page_wait_mach=%llu page_cache_hits=%llu runnable=%llu secure=%llu neural=%llu/%llu conclave=%llu lifemax_fp=%llu intmax_fp=%llu wired=%llu resident=%llu cpu=%llu\n",
        s[44], s[45], s[46], s[47], s[48], s[49], r.ri_pageins, r.ri_page_wait_time_mach, r.ri_page_cache_hits, r.ri_runnable_time, r.ri_secure_time_in_system, r.ri_neural_footprint, r.ri_lifetime_max_neural_footprint, r.ri_conclave_footprint, r.ri_lifetime_max_phys_footprint, r.ri_interval_max_phys_footprint, r.ri_wired_size, r.ri_resident_size, r.ri_user_time + r.ri_system_time); }
    if (s[45]) { n45++; }
  }
  return 0; }
