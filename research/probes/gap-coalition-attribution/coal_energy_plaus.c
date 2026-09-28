// coal_energy_plaus.c - plausibility of lifetime energy slots for foreign vs same-uid coalitions:
// W while running = energy(11) / sum(eqos) CPU-seconds; GPU W while busy = gpu_energy_nj(41) / gpu_time(8); ANE W = 39 / 38.
// build: xcrun clang -O1 -o coal_energy_plaus coal_energy_plaus.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <mach/mach_time.h>
typedef int (*cru_fn)(uint64_t, void *, size_t); typedef int (*pl_fn)(uint64_t, void *, size_t *); typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
int main(void) {
  cru_fn cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl_fn pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc_fn lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double t2s = (double)tb.numer / tb.denom / 1e9; uid_t me = getuid();
  int bytes = lc(2, 0, NULL, 0); struct coalinfo *ci = malloc(bytes + 8192); bytes = lc(2, 0, ci, bytes + 8192); int nc = bytes / sizeof *ci;
  static double wf[4096], ws[4096]; int nf = 0, ns = 0;
  printf("%-24s %-5s %9s %9s %8s | %9s %9s %8s\n", "coalition lead", "uid", "cpu s", "energy J", "W/cpu-s", "gpu s", "gpuE J", "W/gpu-s");
  for (int i = 0; i < nc; i++) { pid_t p[128]; size_t sz = sizeof p; if (pl(ci[i].cid, p, &sz)) continue; int n = sz / sizeof(pid_t); if (!n) continue;
    uint64_t s[50]; if (cru(ci[i].cid, s, sizeof s)) continue; uint64_t q = 0; for (int k = 24; k <= 30; k++) q += s[k]; double cs = q * t2s; if (cs < 5) continue;
    int foreign = 0, uid = -1; char nm[64] = ""; for (int k = 0; k < n; k++) { struct proc_bsdshortinfo si; if (proc_pidinfo(p[k], PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) == sizeof si) { if (si.pbsi_uid != me) foreign = 1; if (!nm[0] || si.pbsi_uid == 0) { strncpy(nm, si.pbsi_comm, 63); uid = si.pbsi_uid; } } }
    double w = s[11] / 1e9 / cs; if (foreign) wf[nf++] = w; else ws[ns++] = w;
    if ((foreign && cs > 60) || s[8] > 10000000000ull) printf("%-24.24s %-5d %9.1f %9.1f %8.3f | %9.1f %9.1f %8.2f%s\n", nm, uid, cs, s[11] / 1e9, w, s[8] / 1e9, s[41] / 1e9, s[8] ? s[41] / 1e9 / (s[8] / 1e9) : 0, foreign ? "  (foreign)" : ""); }
  qsort(wf, nf, 8, cmp); qsort(ws, ns, 8, cmp);
  printf("\nW per CPU-second (lifetime, coalitions with >=5 CPU-s): foreign n=%d p10=%.3f median=%.3f p90=%.3f | same-uid n=%d p10=%.3f median=%.3f p90=%.3f\n", nf, wf[nf / 10], wf[nf / 2], wf[nf * 9 / 10], ns, ws[ns / 10], ws[ns / 2], ws[ns * 9 / 10]);
  return 0; }
