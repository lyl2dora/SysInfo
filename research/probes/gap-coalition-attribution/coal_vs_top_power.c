// coal_vs_top_power.c - variant printing only rows where top POWER != top %CPU or idle wakeups >= 2/s, to fit the POWER formula. (3) for ALL resource coalitions, sample coalition_info_resource_usage at the moments the setuid
// /usr/bin/top prints its two sample headers (`top -l 2 -s 2`), derive per-coalition %CPU / energy W / wakeups/s / GPU%,
// and compare with top's %CPU and POWER for pids that are the sole member of their coalition (esp. foreign uids).
// Read-only. build: xcrun clang -O1 -o coal_vs_top coal_vs_top.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <mach/mach_time.h>
typedef int (*cru_fn)(uint64_t, void *, size_t); typedef int (*pl_fn)(uint64_t, void *, size_t *); typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
typedef struct { uint64_t cid; uint64_t a[50], b[50]; int oka, okb; int np; pid_t pid[64]; } C;
static C cs[4096]; static int nc; static cru_fn cru; static pl_fn pl; static lc_fn lc; static uint64_t ta, tb;
static void list(void) { int bytes = lc(2, 0, NULL, 0); struct coalinfo *ci = malloc(bytes + 8192); bytes = lc(2, 0, ci, bytes + 8192); nc = bytes / sizeof *ci;
  for (int i = 0; i < nc; i++) { cs[i].cid = ci[i].cid; size_t sz = sizeof cs[i].pid; cs[i].np = pl(ci[i].cid, cs[i].pid, &sz) == 0 ? (int)(sz / sizeof(pid_t)) : -1; } free(ci); }
static void sample(int which) { uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); for (int i = 0; i < nc; i++) { if (which == 0) cs[i].oka = cru(cs[i].cid, cs[i].a, sizeof cs[i].a) == 0; else cs[i].okb = cru(cs[i].cid, cs[i].b, sizeof cs[i].b) == 0; }
  if (which == 0) ta = t; else tb = t; }
typedef struct { int pid; double cpu, power; long idlew; char cmd[64]; } T; static T tt[4096]; static int ntt;
static T *tfind(int pid) { for (int i = 0; i < ntt; i++) if (tt[i].pid == pid) return &tt[i]; return NULL; }
int main(int argc, char **argv) {
  int rounds = argc > 1 ? atoi(argv[1]) : 3;
  cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  mach_timebase_info_data_t tbi; mach_timebase_info(&tbi); double t2n = (double)tbi.numer / tbi.denom; uid_t me = getuid();
  double se_all = 0, se_named = 0; int n_all = 0; double maxerr = 0; double errs[8192]; int nerr = 0;
  double sx = 0, sy = 0, sxx = 0, sxy = 0; int nfit = 0; // POWER vs cpu% fit, later wakeups
  for (int r = 0; r < rounds; r++) {
    list(); ntt = 0;
    FILE *f = popen("/usr/bin/top -l 2 -s 2 -o pid -n 5000 -stats pid,command,cpu,power,idlew 2>&1", "r");
    char line[512]; int hdr = 0, intable = 0;
    while (fgets(line, sizeof line, f)) {
      if (!strncmp(line, "Processes:", 10)) { sample(hdr == 0 ? 0 : 1); hdr++; intable = 0; continue; }
      if (!strncmp(line, "PID", 3)) { intable = 1; continue; }
      if (hdr == 2 && intable) { T t = {0}; char cmd[64]; int pid; double cpu, pw; long iw;
        if (sscanf(line, "%d %63s", &pid, cmd) == 2) { // command may contain spaces: parse numbers from the right
          char *p = line + strlen(line); while (p > line && (p[-1] == '\n' || p[-1] == ' ')) p--; *p = 0;
          char *s3 = strrchr(line, ' '); iw = atol(s3 + 1); *s3 = 0; while (s3 > line && s3[-1] == ' ') *--s3 = 0;
          char *s2 = strrchr(line, ' '); pw = atof(s2 + 1); *s2 = 0; while (s2 > line && s2[-1] == ' ') *--s2 = 0;
          char *s1 = strrchr(line, ' '); cpu = atof(s1 + 1);
          t.pid = pid; t.cpu = cpu; t.power = pw; t.idlew = iw; strncpy(t.cmd, cmd, 63); if (ntt < 4096) tt[ntt++] = t; } }
    }
    pclose(f);
    double dt = (tb - ta) / 1e9;
    printf("=== round %d: coalitions=%d, top rows=%d, our sample interval between top headers = %.3f s\n", r, nc, ntt, dt);
    printf("%-6s %-18s %-5s %-6s %8s %8s %8s | %9s %9s %8s %8s %8s %7s\n", "pid", "command", "uid", "cid", "top%CPU", "coal%CPU", "abs_err", "topPOWER", "coal_W", "idlew/s", "intw/s", "topIDLEW", "gpu%");
    for (int i = 0; i < nc; i++) {
      if (!cs[i].oka || !cs[i].okb || cs[i].np != 1) continue;
      pid_t p = cs[i].pid[0]; T *t = tfind(p); if (!t) continue;
      struct proc_bsdshortinfo si; if (proc_pidinfo(p, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) != sizeof si) continue;
      double cpu = (cs[i].b[3] - cs[i].a[3]) * t2n / 1e9 / dt * 100, w = (cs[i].b[11] - cs[i].a[11]) / 1e9 / dt;
      double iw = (cs[i].b[5] - cs[i].a[5]) / dt, inw = (cs[i].b[4] - cs[i].a[4]) / dt, gpu = (cs[i].b[8] - cs[i].a[8]) / 1e9 / dt * 100;
      double err = fabs(cpu - t->cpu); errs[nerr++] = err; if (err > maxerr) maxerr = err; se_all += err; n_all++;
      if (t->power > 0 || cpu > 0.05) { sx += cpu; sy += t->power; sxx += cpu * cpu; sxy += cpu * t->power; nfit++; }
      int named = !strcmp(si.pbsi_comm, "logd") || !strcmp(si.pbsi_comm, "mds") || !strcmp(si.pbsi_comm, "WindowServer") || !strcmp(si.pbsi_comm, "mds_stores") || !strcmp(si.pbsi_comm, "bluetoothd") || !strcmp(si.pbsi_comm, "kernel_task") || !strcmp(si.pbsi_comm, "coreaudiod") || !strcmp(si.pbsi_comm, "powerd");
      if (fabs(t->power - t->cpu) >= 0.1 || iw >= 2) printf("%-6d %-18.18s %-5d %-6llu %8.2f %8.2f %8.2f | %9.2f %9.4f %8.1f %8.1f %8ld %7.2f%s\n", p, si.pbsi_comm, si.pbsi_uid, cs[i].cid, t->cpu, cpu, err, t->power, w, iw, inw, t->idlew, gpu, si.pbsi_uid != me ? "  (foreign)" : "");
    }
    // multi-member coalitions of interest: cid 1 (kernel_task+launchd) and WindowServer's
    for (int i = 0; i < nc; i++) { if (!cs[i].oka || !cs[i].okb || cs[i].np < 2) continue; int show = cs[i].cid == 1; double topsum = 0; char names[256] = "";
      for (int k = 0; k < cs[i].np; k++) { T *t = tfind(cs[i].pid[k]); if (t) topsum += t->cpu; struct proc_bsdshortinfo si; if (proc_pidinfo(cs[i].pid[k], PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) == sizeof si) { if (!strcmp(si.pbsi_comm, "WindowServer")) show = 1; if (strlen(names) < 200) { strcat(names, si.pbsi_comm); strcat(names, ","); } } }
      if (!show) continue; double cpu = (cs[i].b[3] - cs[i].a[3]) * t2n / 1e9 / dt * 100;
      printf("  multi-member cid %llu [%s] members=%d: sum(top %%CPU)=%.2f coalition %%CPU=%.2f abs_err=%.2f energy=%.3f W gpu%%=%.2f\n", cs[i].cid, names, cs[i].np, topsum, cpu, fabs(topsum - cpu), (cs[i].b[11] - cs[i].a[11]) / 1e9 / dt, (cs[i].b[8] - cs[i].a[8]) / 1e9 / dt * 100); }
    // kernel_task alone
    { T *t = tfind(0); if (t) printf("  top kernel_task (pid 0): %%CPU=%.2f POWER=%.2f\n", t->cpu, t->power); }
  }
  // summary
  for (int i = 0; i < nerr; i++) for (int j = i + 1; j < nerr; j++) if (errs[j] < errs[i]) { double x = errs[i]; errs[i] = errs[j]; errs[j] = x; }
  printf("\nSUMMARY single-member coalitions matched to top rows: n=%d  mean |err| = %.3f pp  median = %.3f pp  p95 = %.3f pp  max = %.3f pp\n", n_all, se_all / n_all, errs[nerr / 2], errs[(int)(nerr * 0.95)], maxerr);
  double slope = (nfit * sxy - sx * sy) / (nfit * sxx - sx * sx), icpt = (sy - slope * sx) / nfit; printf("least squares top POWER = %.3f * coal%%CPU + %.3f over %d active rows\n", slope, icpt, nfit);
  return 0; }
