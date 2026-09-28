// cru_unknown2.c - compare slots 44-48 with PROC_PIDTASKINFO counters (faults, pageins, cow_faults, messages, syscalls, csw)
// for same-uid single-member coalitions. build: xcrun clang -O1 -o cru_unknown2 cru_unknown2.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>
typedef int (*cru_fn)(uint64_t, void *, size_t); typedef int (*pl_fn)(uint64_t, void *, size_t *); typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
int main(void) {
  cru_fn cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl_fn pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc_fn lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  int bytes = lc(2, 0, NULL, 0); struct coalinfo *ci = malloc(bytes + 4096); bytes = lc(2, 0, ci, bytes + 4096); int nc = bytes / sizeof *ci; int shown = 0;
  const char *fn[8] = {"faults", "pageins", "cow_faults", "msgs_sent", "msgs_rcvd", "sysc_mach", "sysc_unix", "csw"};
  int hit[50][8] = {{0}}, both[50][8] = {{0}}, used = 0;
  for (int i = 0; i < nc; i++) {
    pid_t p[64]; size_t sz = sizeof p; if (pl(ci[i].cid, p, &sz) != 0 || sz != sizeof(pid_t)) continue;
    struct proc_taskinfo ti; if (proc_pidinfo(p[0], PROC_PIDTASKINFO, 0, &ti, sizeof ti) != sizeof ti) continue;
    uint64_t s[50]; if (cru(ci[i].cid, s, sizeof s)) continue; if (s[0] > 2) continue; used++;
    uint64_t f[8] = {(uint64_t)ti.pti_faults, (uint64_t)ti.pti_pageins, (uint64_t)ti.pti_cow_faults, (uint64_t)ti.pti_messages_sent, (uint64_t)ti.pti_messages_received, (uint64_t)ti.pti_syscalls_mach, (uint64_t)ti.pti_syscalls_unix, (uint64_t)ti.pti_csw};
    for (int k = 44; k < 50; k++) for (int j = 0; j < 8; j++) { if (!s[k] || !f[j]) continue; both[k][j]++; if (fabs((double)s[k] / f[j] - 1) <= 0.03) hit[k][j]++; }
    if (shown < 8) { shown++; char nm[64] = ""; proc_name(p[0], nm, sizeof nm);
      printf("%-20.20s s44=%llu s45=%llu s46=%llu s47=%llu s48=%llu s49=%llu | faults=%d pageins=%d cow=%d msent=%d mrcvd=%d mach=%d unix=%d csw=%d threads=%d\n", nm, s[44], s[45], s[46], s[47], s[48], s[49],
        ti.pti_faults, ti.pti_pageins, ti.pti_cow_faults, ti.pti_messages_sent, ti.pti_messages_received, ti.pti_syscalls_mach, ti.pti_syscalls_unix, ti.pti_csw, ti.pti_threadnum); }
  }
  printf("single-member same-uid coalitions used: %d\n", used);
  for (int k = 44; k < 50; k++) for (int j = 0; j < 8; j++) if (both[k][j] >= 5) printf("slot %d vs pti_%-10s within 3%%: %d/%d\n", k, fn[j], hit[k][j], both[k][j]);
  return 0; }
