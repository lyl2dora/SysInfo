// coal_gap.c - coalition 的 CPU 增量为什么会大于「成员 rusage 增量之和」：窗口内没有成员进出（slot 0/1 不变）、
// 且成员全部同 uid 可读时，逐个 coalition 打印 rest = Δeqos − Σ成员 Δ(user+system)，并与 Δslot3、Δslot9/10
// （cpu_time_billed_to_me / billed_to_others）、成员 Δri_billed_system_time / Δri_serviced_system_time、Δenergy 对照。只读。
// 用法：coal_gap [窗口秒=2]
// build: xcrun clang -O1 -o coal_gap coal_gap.c
#include "coal.h"
#include <math.h>
#define MAXC 4096
typedef struct { uint64_t cid; uint64_t s[COAL_SLOTS]; int np; pid_t pid[64]; struct rusage_info_v6 ru[64]; int rok[64]; } C;
static C A[MAXC], B[MAXC]; static int na, nb;
static int take(C *out) { struct coal_listent *li; int n = coal_list(&li), k = 0;
  for (int i = 0; i < n; i++) { if (!li[i].tasks || li[i].tasks > 64) continue; C *c = &out[k]; c->cid = li[i].cid; if (coal_cru(c->cid, c->s, sizeof c->s)) continue;
    size_t sz = sizeof c->pid; if (coal_pl(c->cid, c->pid, &sz)) continue; c->np = sz / sizeof(pid_t); for (int m = 0; m < c->np; m++) c->rok[m] = rusage6(c->pid[m], &c->ru[m]); k++; }
  free(li); return k; }
int main(int argc, char **argv) { double win = argc > 1 ? atof(argv[1]) : 2; print_machine(); coal_init(); double k = tick_to_ns() / 1e9;
  na = take(A); uint64_t t0 = now_ns(); usleep((useconds_t)(win * 1e6)); nb = take(B); double dt = (now_ns() - t0) / 1e9;
  printf("window %.3f s; rows: coalitions with no membership change, all members readable (same uid), and (dCPU >= 0.5%% or |rest| >= 0.2%%)\n", dt);
  printf("%-7s %-24s %2s %8s %8s %8s %8s %9s %9s %9s %9s\n", "cid", "first member", "n", "eqos%", "members%", "rest%", "slot3%", "slot9%", "slot10%", "mbilled%", "mserv%");
  double srest_single = 0, srest_multi = 0, scpu_single = 0, scpu_multi = 0; int ns = 0, nm = 0;
  for (int i = 0; i < nb; i++) { C *b = &B[i], *a = NULL; for (int j = 0; j < na; j++) if (A[j].cid == b->cid) { a = &A[j]; break; } if (!a) continue;
    if (a->s[0] != b->s[0] || a->s[1] != b->s[1] || a->np != b->np) continue; int ok = 1; for (int m = 0; m < b->np; m++) if (a->pid[m] != b->pid[m] || !a->rok[m] || !b->rok[m]) ok = 0; if (!ok) continue;
    double eq = (coal_cpu_ticks(b->s) - coal_cpu_ticks(a->s)) * k / dt * 100, s3 = (b->s[3] - a->s[3]) * k / dt * 100, s9 = (b->s[9] - a->s[9]) * k / dt * 100, s10 = (b->s[10] - a->s[10]) * k / dt * 100;
    double mem = 0, mb = 0, ms = 0; for (int m = 0; m < b->np; m++) { mem += ((b->ru[m].ri_user_time + b->ru[m].ri_system_time) - (a->ru[m].ri_user_time + a->ru[m].ri_system_time)) * k / dt * 100;
      mb += (b->ru[m].ri_billed_system_time - a->ru[m].ri_billed_system_time) * k / dt * 100; ms += (b->ru[m].ri_serviced_system_time - a->ru[m].ri_serviced_system_time) * k / dt * 100; }
    double rest = eq - mem; if (b->np == 1) { srest_single += fabs(rest); scpu_single += eq; ns++; } else { srest_multi += fabs(rest); scpu_multi += eq; nm++; }
    if (eq >= 0.5 || fabs(rest) >= 0.2) { struct proc_bsdshortinfo si; char nmn[32] = "?"; if (shortinfo(b->pid[0], &si)) snprintf(nmn, sizeof nmn, "%s", si.pbsi_comm);
      printf("%-7llu %-24s %2d %8.2f %8.2f %8.2f %8.2f %9.2f %9.2f %9.2f %9.2f\n", b->cid, nmn, b->np, eq, mem, rest, s3, s9, s10, mb, ms); } }
  printf("single-member: n=%d sum|rest| %.2f pp over sum CPU %.2f%%; multi-member: n=%d sum|rest| %.2f pp over sum CPU %.2f%%\n", ns, srest_single, scpu_single, nm, srest_multi, scpu_multi);
  return 0; }
