// topn_vs_top.c - 每进程 / 每 coalition CPU% 与 setuid 的 /usr/bin/top 对照。只读。
// 用法：topn_vs_top <间隔秒 1|2> <轮数> [关注的 pid ...]
// 在 top 打印两次采样表头（"Processes:"）的时刻各取一次：全部 coalition 的 resource usage（CPU = eqos 槽 24..30 之和）
// 和全部同 uid 进程的 proc_pid_rusage(V6)。然后对比：
//   (a) 单成员 coalition 的 CPU% vs top（全体 / 其他 uid）
//   (b) 同 uid 进程 libproc CPU% vs top
//   (c) 多成员 coalition 的 CPU% vs 成员 top CPU% 之和
//   (d) 「每进程估计」：同 uid → libproc；单成员 coalition → coalition；多成员里只剩一个不可读成员 → 残差；否则只能按组
//       并看 top 前 10 名进程里有多少能被精确给出
//   (e) 关注 pid（例如 burn）逐行打印：top / libproc / 所在 coalition / ptime 占比
// build: xcrun clang -O1 -o topn_vs_top topn_vs_top.c
#include "coal.h"
#include <math.h>

#define MAXC 4096
#define MAXP 16384
typedef struct { uint64_t cid; uint64_t s[COAL_SLOTS]; int ok; int np; pid_t *pid; } CS;
typedef struct { uint64_t t; int nc; CS c[MAXC]; int npid; pid_t pid[MAXP]; int rok[MAXP]; struct rusage_info_v6 ru[MAXP]; } SNAP;
static SNAP S[2];
static struct coal_listent *LI; static int NL;

static void take(SNAP *s) {
  s->t = now_ns(); s->nc = NL;
  for (int i = 0; i < NL; i++) { CS *c = &s->c[i]; c->cid = LI[i].cid; c->ok = coal_cru(c->cid, c->s, sizeof c->s) == 0;
    size_t cap = (LI[i].tasks + 16) * sizeof(pid_t); free(c->pid); c->pid = malloc(cap); size_t sz = cap; c->np = coal_pl(c->cid, c->pid, &sz) == 0 ? (int)(sz / sizeof(pid_t)) : 0; }
  s->npid = proc_listallpids(s->pid, sizeof s->pid);
  for (int i = 0; i < s->npid; i++) s->rok[i] = rusage6(s->pid[i], &s->ru[i]);
}
static int pidx(SNAP *s, pid_t p) { for (int i = 0; i < s->npid; i++) if (s->pid[i] == p) return i; return -1; }
static CS *cfind(SNAP *s, uint64_t cid) { for (int i = 0; i < s->nc; i++) if (s->c[i].cid == cid) return &s->c[i]; return NULL; }

typedef struct { int pid; double cpu; double time; char cmd[128]; } T; static T tt[MAXP]; static int ntt;
static int t1pid[MAXP]; static double t1time[MAXP]; static int nt1;
static double t1find(int pid) { for (int i = 0; i < nt1; i++) if (t1pid[i] == pid) return t1time[i]; return NAN; }
static double parse_time(const char *tm) { int a = 0, b = 0, c = 0, hs = 0; if (!strchr(tm, '.') && sscanf(tm, "%d:%d:%d", &a, &b, &c) == 3) return a * 3600 + b * 60 + c; if (sscanf(tm, "%d:%d.%d", &a, &b, &hs) == 3) return a * 60 + b + hs / 100.0; return NAN; }
static double rat_top[4096], rat_time[4096]; static int nrat;
static T *tfind(int pid) { for (int i = 0; i < ntt; i++) if (tt[i].pid == pid) return &tt[i]; return NULL; }
static int cmp_tcpu(const void *a, const void *b) { double x = ((const T *)a)->cpu, y = ((const T *)b)->cpu; return x < y ? 1 : x > y ? -1 : 0; }

static double ea[65536], eb[65536], ec[65536]; static int na, nb, nc_; static int naf;
static double maxa, maxb, maxc;

int main(int argc, char **argv) {
  int iv = argc > 1 ? atoi(argv[1]) : 2, rounds = argc > 2 ? atoi(argv[2]) : 3; int watch[16], nw = 0; for (int i = 3; i < argc && nw < 16; i++) watch[nw++] = atoi(argv[i]);
  print_machine(); coal_init(); uid_t me = getuid(); double k = tick_to_ns() / 1e9;
  int top10_total = 0, top10_exact = 0, top10_group = 0;
  for (int r = 0; r < rounds; r++) {
    free(LI); NL = coal_list(&LI); ntt = 0; nt1 = 0;
    char cmd[256]; snprintf(cmd, sizeof cmd, "/usr/bin/top -l 2 -s %d -o pid -n 20000 -stats pid,cpu,time,command 2>/dev/null", iv);
    FILE *f = popen(cmd, "r"); char line[512]; int hdr = 0, intable = 0;
    while (fgets(line, sizeof line, f)) {
      if (!strncmp(line, "Processes:", 10)) { take(&S[hdr > 0]); hdr++; intable = 0; continue; }
      if (!strncmp(line, "PID", 3)) { intable = 1; continue; }
      if (intable && ntt < MAXP) { T t = {0}; int off = 0; char tm[64]; if (sscanf(line, "%d %lf %63s %n", &t.pid, &t.cpu, tm, &off) >= 3) { t.time = parse_time(tm);
          if (hdr == 1) { t1pid[nt1] = t.pid; t1time[nt1++] = t.time; } else if (hdr == 2) { strncpy(t.cmd, line + off, 127); t.cmd[strcspn(t.cmd, "\n")] = 0; tt[ntt++] = t; } } }
    }
    pclose(f);
    SNAP *A = &S[0], *B = &S[1]; double dt = (B->t - A->t) / 1e9;
    printf("=== round %d: interval %d s, our window between top headers %.3f s, coalitions %d, top rows %d, pids %d\n", r, iv, dt, B->nc, ntt, B->npid);
    // (a) 单成员 coalition
    for (int i = 0; i < B->nc; i++) { CS *b = &B->c[i], *a = cfind(A, b->cid); if (!a || !a->ok || !b->ok || b->np != 1 || a->np != 1 || a->pid[0] != b->pid[0]) continue;
      T *t = tfind(b->pid[0]); if (!t) continue; double c = (coal_cpu_ticks(b->s) - coal_cpu_ticks(a->s)) * k / dt * 100; double e = fabs(c - t->cpu);
      ea[na++] = e; if (e > maxa) maxa = e; struct proc_bsdshortinfo si; if (shortinfo(b->pid[0], &si) && si.pbsi_uid != me) naf++; }
    // (b) 同 uid libproc
    for (int i = 0; i < B->npid; i++) { if (!B->rok[i]) continue; int j = pidx(A, B->pid[i]); if (j < 0 || !A->rok[j]) continue; T *t = tfind(B->pid[i]); if (!t) continue;
      double c = ((B->ru[i].ri_user_time + B->ru[i].ri_system_time) - (A->ru[j].ri_user_time + A->ru[j].ri_system_time)) * k / dt * 100; double e = fabs(c - t->cpu); eb[nb++] = e; if (e > maxb) maxb = e; }
    // (c) 多成员 coalition：成员集合前后不变的才比
    int shown = 0;
    for (int i = 0; i < B->nc; i++) { CS *b = &B->c[i], *a = cfind(A, b->cid); if (!a || !a->ok || !b->ok || b->np < 2 || a->np != b->np) continue;
      int same = 1; for (int m = 0; m < b->np; m++) if (a->pid[m] != b->pid[m]) same = 0; if (!same) continue;
      double sum = 0; int miss = 0; for (int m = 0; m < b->np; m++) { T *t = tfind(b->pid[m]); if (t) sum += t->cpu; else miss++; } if (miss) continue;
      double c = (coal_cpu_ticks(b->s) - coal_cpu_ticks(a->s)) * k / dt * 100; double e = fabs(c - sum); ec[nc_++] = e; if (e > maxc) maxc = e;
      if ((c >= 3 || e >= 0.5) && shown < 8) { struct proc_bsdshortinfo si; char nm[40] = "?"; if (shortinfo(b->pid[0], &si)) snprintf(nm, sizeof nm, "%s", si.pbsi_comm);
        printf("   multi-member cid %-6llu first=%-16s members=%-3d coalition %6.2f%%  sum(top members) %6.2f%%  |err| %.2f\n", b->cid, nm, b->np, c, sum, e); shown++; } }
    // (d) top 前 10 名进程能否被「每进程」精确给出
    qsort(tt, ntt, sizeof *tt, cmp_tcpu);
    printf("   top-10 processes by top %%CPU vs our per-process estimate (exact source) :\n");
    for (int q = 0; q < 10 && q < ntt; q++) { T *t = &tt[q]; int i = pidx(B, t->pid), j = pidx(A, t->pid); double est = NAN; const char *src = "group-only";
      if (i >= 0 && j >= 0 && B->rok[i] && A->rok[j]) { est = ((B->ru[i].ri_user_time + B->ru[i].ri_system_time) - (A->ru[j].ri_user_time + A->ru[j].ri_system_time)) * k / dt * 100; src = "libproc"; }
      else { uint64_t cid = coal_of_pid(t->pid); CS *b = cfind(B, cid), *a = cfind(A, cid);
        if (a && b && a->ok && b->ok) { double c = (coal_cpu_ticks(b->s) - coal_cpu_ticks(a->s)) * k / dt * 100;
          if (b->np == 1) { est = c; src = "coalition(sole)"; }
          else { int unread = 0; double known = 0; for (int m = 0; m < b->np; m++) { int bi = pidx(B, b->pid[m]), ai = pidx(A, b->pid[m]);
                if (bi >= 0 && ai >= 0 && B->rok[bi] && A->rok[ai]) known += ((B->ru[bi].ri_user_time + B->ru[bi].ri_system_time) - (A->ru[ai].ri_user_time + A->ru[ai].ri_system_time)) * k / dt * 100; else unread++; }
            if (unread == 1) { est = c - known; src = "coalition-residual"; } else { est = c; src = "group-only"; } } } }
      top10_total++; if (!strcmp(src, "group-only")) top10_group++; else if (fabs(est - t->cpu) <= fmax(0.5, t->cpu * 0.05)) top10_exact++;
      double tr = (t->time - t1find(t->pid)) / dt * 100;
      if (t->cpu >= 20 && !isnan(est) && strcmp(src, "group-only") && nrat < 4096) { rat_top[nrat] = est / t->cpu; rat_time[nrat++] = est / tr; }
      printf("     #%-2d pid %-6d %-28.28s top %6.2f%%  top-dTIME/dt %6.1f%%  ours %6.2f%%  [%s]\n", q + 1, t->pid, t->cmd, t->cpu, tr, est, src); }
    // (e) 关注 pid
    for (int w = 0; w < nw; w++) { T *t = tfind(watch[w]); int i = pidx(B, watch[w]), j = pidx(A, watch[w]); if (!t || i < 0 || j < 0) { printf("   watch pid %d: not in both samples\n", watch[w]); continue; }
      struct rusage_info_v6 *rb = &B->ru[i], *ra = &A->ru[j]; double c = B->rok[i] && A->rok[j] ? ((rb->ri_user_time + rb->ri_system_time) - (ra->ri_user_time + ra->ri_system_time)) * k / dt * 100 : NAN;
      double pt = B->rok[i] && A->rok[j] ? ((rb->ri_user_ptime + rb->ri_system_ptime) - (ra->ri_user_ptime + ra->ri_system_ptime)) * k / dt * 100 : NAN;
      double w_ = B->rok[i] && A->rok[j] ? (rb->ri_energy_nj - ra->ri_energy_nj) / 1e9 / dt : NAN;
      uint64_t cid = coal_of_pid(watch[w]); CS *b = cfind(B, cid), *a = cfind(A, cid); double cc = (a && b) ? (coal_cpu_ticks(b->s) - coal_cpu_ticks(a->s)) * k / dt * 100 : NAN;
      printf("   watch pid %d (%s): top %.2f%%  libproc %.2f%% (on perflevel0 %.2f%%, %.3f W)  its coalition %llu (%d members) %.2f%%\n", watch[w], t->cmd, t->cpu, c, pt, w_, cid, b ? b->np : -1, cc); }
  }
  double va[65536], vb[65536], vc[65536]; memcpy(va, ea, na * sizeof(double)); memcpy(vb, eb, nb * sizeof(double)); memcpy(vc, ec, nc_ * sizeof(double));
  double sa = 0, sb = 0, sc = 0; for (int i = 0; i < na; i++) sa += ea[i]; for (int i = 0; i < nb; i++) sb += eb[i]; for (int i = 0; i < nc_; i++) sc += ec[i];
  printf("\nSUMMARY (interval %d s, %d rounds), |ours - top| in CPU percentage points (100 = one core):\n", iv, rounds);
  printf("  (a) single-member coalitions : n=%d (foreign %d)  mean %.3f  median %.3f  p95 %.3f  max %.3f\n", na, naf, na ? sa / na : 0, median(va, na), pct(va, na, 0.95), maxa);
  printf("  (b) same-uid libproc         : n=%d  mean %.3f  median %.3f  p95 %.3f  max %.3f\n", nb, nb ? sb / nb : 0, median(vb, nb), pct(vb, nb, 0.95), maxb);
  printf("  (c) multi-member coalitions  : n=%d  mean %.3f  median %.3f  p95 %.3f  max %.3f\n", nc_, nc_ ? sc / nc_ : 0, median(vc, nc_), pct(vc, nc_, 0.95), maxc);
  { double a = 0, b = 0; for (int i = 0; i < nrat; i++) { a += rat_top[i]; b += rat_time[i]; }
    printf("  busy (top %%CPU>=20) exact rows: n=%d  mean ours/top%%CPU = %.3f   mean ours/(top dTIME / our dt) = %.3f\n", nrat, nrat ? a / nrat : 0, nrat ? b / nrat : 0); }
  printf("  (d) top-10 processes: %d rows, exact per-process (<=0.5pp or 5%%) %d, group-only %d\n", top10_total, top10_exact, top10_group);
  return 0;
}
