// cru_fieldmatch.c - statistical slot identification: for every SAME-UID resource coalition that currently has exactly
// ONE member (so the coalition totals ~= that task's lifetime rusage, plus a tiny pre-exec xpcproxy task), compare every
// coalition_resource_usage u64 slot with every u64 field of proc_pid_rusage(RUSAGE_INFO_V6) of that member,
// raw and with mach-tick<->ns conversion (timebase 125/3).  A slot "matches" a field when |slot/field-1| <= 2%
// for >= 60% of coalitions where both are non-zero.  Read-only.
// build: xcrun clang -O1 -o cru_fieldmatch cru_fieldmatch.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <unistd.h>
#include <dlfcn.h>
#include <math.h>
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#define NS 50
typedef int (*cru_fn)(uint64_t, void *, size_t);
typedef int (*pl_fn)(uint64_t, void *, size_t *);
typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
#define F(x) {#x, offsetof(struct rusage_info_v6, x)}
static struct { const char *n; size_t off; } FL[] = {
 F(ri_user_time),F(ri_system_time),F(ri_pkg_idle_wkups),F(ri_interrupt_wkups),F(ri_pageins),F(ri_wired_size),F(ri_resident_size),F(ri_phys_footprint),
 F(ri_proc_start_abstime),F(ri_child_user_time),F(ri_diskio_bytesread),F(ri_diskio_byteswritten),F(ri_cpu_time_qos_default),F(ri_cpu_time_qos_maintenance),
 F(ri_cpu_time_qos_background),F(ri_cpu_time_qos_utility),F(ri_cpu_time_qos_legacy),F(ri_cpu_time_qos_user_initiated),F(ri_cpu_time_qos_user_interactive),
 F(ri_billed_system_time),F(ri_serviced_system_time),F(ri_logical_writes),F(ri_lifetime_max_phys_footprint),F(ri_instructions),F(ri_cycles),F(ri_billed_energy),
 F(ri_serviced_energy),F(ri_interval_max_phys_footprint),F(ri_runnable_time),F(ri_flags),F(ri_user_ptime),F(ri_system_ptime),F(ri_pinstructions),F(ri_pcycles),
 F(ri_energy_nj),F(ri_penergy_nj),F(ri_secure_time_in_system),F(ri_secure_ptime_in_system),F(ri_neural_footprint),F(ri_lifetime_max_neural_footprint),
 F(ri_interval_max_neural_footprint),F(ri_conclave_footprint),F(ri_page_wait_time_mach),F(ri_page_cache_hits),
 {"user+system_time", 1000}, {"user+system_ptime", 1001} };
#define NF (int)(sizeof FL / sizeof FL[0])
static uint64_t fv(const struct rusage_info_v6 *r, int f) {
  if (FL[f].off == 1000) return r->ri_user_time + r->ri_system_time;
  if (FL[f].off == 1001) return r->ri_user_ptime + r->ri_system_ptime;
  return *(const uint64_t *)((const char *)r + FL[f].off); }
int main(void) {
  cru_fn cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl_fn pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc_fn lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double t2n = (double)tb.numer / tb.denom;
  int bytes = lc(2, 0, NULL, 0); struct coalinfo *ci = malloc(bytes + 4096); bytes = lc(2, 0, ci, bytes + 4096); int nc = bytes / sizeof *ci;
  static int hit[NS][NF][3], both[NS][NF]; int used = 0; uid_t me = getuid();
  uint64_t sampleS[NS] = {0}; char samplename[64] = "";
  for (int i = 0; i < nc; i++) {
    pid_t p[64]; size_t sz = sizeof p; if (pl(ci[i].cid, p, &sz) != 0 || sz != sizeof(pid_t)) continue;
    struct rusage_info_v6 r; if (proc_pid_rusage(p[0], RUSAGE_INFO_V6, (rusage_info_t *)&r) != 0) continue; // same-uid only
    uint64_t s[NS]; memset(s, 0, sizeof s); if (cru(ci[i].cid, s, sizeof s)) continue;
    if (s[1] + 1 != s[0] && s[1] + 2 != s[0]) continue; // tolerate the one exited pre-exec (xpcproxy) task
    used++;
    if (!samplename[0] && s[3] > 1000000000ull) { memcpy(sampleS, s, sizeof s); proc_name(p[0], samplename, sizeof samplename); }
    for (int k = 0; k < NS; k++) for (int f = 0; f < NF; f++) { uint64_t a = s[k], b = fv(&r, f); if (!a || !b) continue; both[k][f]++;
      double q = (double)a / b; if (fabs(q - 1) <= 0.02) hit[k][f][0]++; if (fabs(q / t2n - 1) <= 0.02) hit[k][f][1]++; if (fabs(q * t2n - 1) <= 0.02) hit[k][f][2]++; }
  }
  printf("resource coalitions listed=%d; same-uid single-member coalitions used=%d (uid %d); timebase %u/%u\n", nc, used, me, tb.numer, tb.denom);
  const char *conv[3] = {"x1", "slot=field*125/3 (field in mach ticks, slot in ns)", "slot=field*3/125"};
  for (int k = 0; k < NS; k++) {
    int any = 0; for (int f = 0; f < NF; f++) for (int c = 0; c < 3; c++) if (both[k][f] >= 5 && hit[k][f][c] * 10 >= both[k][f] * 6) {
      printf("slot %2d  ~ %-34s %-48s matched %3d/%3d\n", k, FL[f].n, conv[c], hit[k][f][c], both[k][f]); any = 1; }
    if (!any) { int nz = 0; for (int f = 0; f < NF; f++) if (both[k][f] > nz) nz = both[k][f]; printf("slot %2d  (no rusage field match; coalitions with slot!=0: up to %d)\n", k, nz); }
  }
  printf("\nexample single-member coalition '%s' raw slots:", samplename); for (int k = 0; k < NS; k++) printf(" [%d]=%llu", k, sampleS[k]); printf("\n");
  return 0; }
