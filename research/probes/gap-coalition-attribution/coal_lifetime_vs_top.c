// coal_lifetime_vs_top.c - for single-member coalitions (all uids), compare LIFETIME coalition slots with top's cumulative
// columns from one `top -l 1` snapshot: slot 5 platform_idle_wakeups vs IDLEW, slot 3 cpu_time vs TIME.
// (top gets these via task_power_info / task_info with its com.apple.system-task-ports.read entitlement.)  Read-only.
// build: xcrun clang -O1 -o coal_lifetime_vs_top coal_lifetime_vs_top.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <mach/mach_time.h>
typedef int (*cru_fn)(uint64_t, void *, size_t); typedef int (*pl_fn)(uint64_t, void *, size_t *); typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
int main(void) {
  cru_fn cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl_fn pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc_fn lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double t2n = (double)tb.numer / tb.denom; uid_t me = getuid();
  static int tpid[8192]; static long tidle[8192]; static double ttime[8192]; int nt = 0;
  FILE *f = popen("/usr/bin/top -l 1 -o pid -n 5000 -stats pid,idlew,time 2>&1", "r"); char line[512]; int intable = 0;
  while (fgets(line, sizeof line, f)) { if (!strncmp(line, "PID", 3)) { intable = 1; continue; } if (!intable) continue;
    int pid; long iw; char tm[64]; if (sscanf(line, "%d %ld %63s", &pid, &iw, tm) != 3) continue;
    // TIME formats: mm:ss.xx or hh:mm:ss
    int a = 0, b = 0, c = 0, hs = 0; double secs;
    if (sscanf(tm, "%d:%d:%d", &a, &b, &c) == 3 && !strchr(tm, '.')) secs = a * 3600 + b * 60 + c; else if (sscanf(tm, "%d:%d.%d", &a, &b, &hs) == 3) secs = a * 60 + b + hs / 100.0; else continue;
    tpid[nt] = pid; tidle[nt] = iw; ttime[nt] = secs; nt++; }
  pclose(f);
  int bytes = lc(2, 0, NULL, 0); struct coalinfo *ci = malloc(bytes + 8192); bytes = lc(2, 0, ci, bytes + 8192); int nc = bytes / sizeof *ci;
  int n = 0, nf = 0, idle_ok = 0, time_ok = 0, idle_okf = 0, time_okf = 0, eq_ok = 0, eq_okf = 0; int shown = 0;
  for (int i = 0; i < nc; i++) { pid_t p[8]; size_t sz = sizeof p; if (pl(ci[i].cid, p, &sz) || sz != sizeof(pid_t)) continue;
    uint64_t s[50]; if (cru(ci[i].cid, s, sizeof s)) continue; if (s[0] > 2) continue;
    int k = -1; for (int j = 0; j < nt; j++) if (tpid[j] == p[0]) k = j; if (k < 0) continue;
    struct proc_bsdshortinfo si; if (proc_pidinfo(p[0], PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) != sizeof si) continue; int foreign = si.pbsi_uid != me;
    double cs = s[3] * t2n / 1e9; int iok = labs((long)s[5] - tidle[k]) <= 2 + tidle[k] / 1000; int tok = fabs(cs - ttime[k]) <= 0.02 + ttime[k] * 0.005 || (ttime[k] >= 3600 && fabs(cs - ttime[k]) <= 1.5);
    uint64_t eqs = 0; for (int q = 24; q <= 30; q++) eqs += s[q]; double es = eqs * t2n / 1e9; int eok = fabs(es - ttime[k]) <= 0.02 + ttime[k] * 0.005 || (ttime[k] >= 3600 && fabs(es - ttime[k]) <= 1.5);
    eq_ok += eok; if (foreign) eq_okf += eok;
    n++; idle_ok += iok; time_ok += tok; if (foreign) { nf++; idle_okf += iok; time_okf += tok; }
    if (foreign && shown < 12 && (s[5] > 1000 || cs > 30)) { shown++; printf("  pid %-6d %-18.18s uid %-4d  slot5 idle_wkups=%-9llu top IDLEW=%-9ld | slot3 cpu=%.2f s  sum(eqos 24..30)=%.2f s  top TIME=%.2f s\n", p[0], si.pbsi_comm, si.pbsi_uid, s[5], tidle[k], cs, es, ttime[k]); } }
  printf("single-member coalitions matched to top rows: %d (foreign %d)\n  slot5 == top IDLEW (+-2 or 0.1%%): %d/%d (foreign %d/%d)\n  slot3 (mach ticks->s) == top TIME (+-0.5%%/20ms; 1.5 s when shown as hh:mm:ss): %d/%d (foreign %d/%d)\n", n, nf, idle_ok, n, idle_okf, nf, time_ok, n, time_okf, nf);
  printf("  sum(eqos slots 24..30) == top TIME (same tolerance): %d/%d (foreign %d/%d)\n", eq_ok, n, eq_okf, nf);
  return 0; }
