// scan_cost.c - 进程 Top N 各组成部分的每次开销（线程 CPU 时间），以及按 1 s / 2 s 间隔实跑的整体开销。只读。
// 用法：scan_cost [轮数=60] [实跑秒数=20]
// 第一部分：逐项测 N 次，报 min / 中位数 / p90（ms，线程 CPU 时间）；
// 第二部分：模拟一个真实的 Top N 采样器（coalition 全量 + 同 uid libproc + 前 N 名的成员与路径，路径按 pid+启动时间缓存），
//           分别以 1 s 与 2 s 间隔跑若干秒，报本进程 CPU 时间 / 墙钟（= 单核占比）。
// build: xcrun clang -O1 -o scan_cost scan_cost.c
#include "coal.h"
#include <math.h>
#include <pthread.h>
#include <pthread/qos.h>

#define MAXC 4096
#define MAXP 16384
static struct coal_listent *LI; static int NL;
static uint64_t S[MAXC][COAL_SLOTS];
static pid_t PIDS[MAXP]; static int NP;
static struct proc_bsdshortinfo SI[MAXP]; static int SIok[MAXP];
static struct rusage_info_v6 RU[MAXP];

typedef void (*fn_t)(void);
static void f_list(void) { free(LI); NL = coal_list(&LI); }
static void f_cru_all(void) { for (int i = 0; i < NL; i++) coal_cru(LI[i].cid, S[i], sizeof S[i]); }
static void f_cru_live(void) { for (int i = 0; i < NL; i++) if (LI[i].tasks) coal_cru(LI[i].cid, S[i], sizeof S[i]); }
static void f_pl_all(void) { pid_t buf[4096]; for (int i = 0; i < NL; i++) if (LI[i].tasks) { size_t sz = (LI[i].tasks + 16) * sizeof(pid_t); if (sz > sizeof buf) sz = sizeof buf; coal_pl(LI[i].cid, buf, &sz); } }
static void f_listpids(void) { NP = proc_listallpids(PIDS, sizeof PIDS); }
static void f_short(void) { for (int i = 0; i < NP; i++) SIok[i] = shortinfo(PIDS[i], &SI[i]); }
static void f_ru_all(void) { for (int i = 0; i < NP; i++) rusage6(PIDS[i], &RU[i]); }
static uid_t ME;
static void f_ru_same(void) { for (int i = 0; i < NP; i++) if (SIok[i] && SI[i].pbsi_uid == ME) rusage6(PIDS[i], &RU[i]); }
static void f_path(void) { char p[PROC_PIDPATHINFO_MAXSIZE]; for (int i = 0; i < NP; i++) proc_pidpath(PIDS[i], p, sizeof p); }
static void f_kinfo_all(void) { int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}; size_t sz = 0; sysctl(mib, 3, NULL, &sz, NULL, 0); sz += 64 * sizeof(struct kinfo_proc); void *b = malloc(sz); sysctl(mib, 3, b, &sz, NULL, 0); free(b); }
static void f_pidcoal(void) { for (int i = 0; i < NP; i++) coal_of_pid(PIDS[i]); }
static void f_resp(void) { if (!coal_resp) return; for (int i = 0; i < NP; i++) if (SIok[i] && SI[i].pbsi_uid == ME) coal_resp(PIDS[i]); }
static void f_tick_coal_min(void) { f_list(); f_cru_live(); }
static void f_tick_full(void) { f_list(); f_cru_live(); f_pl_all(); f_listpids(); f_short(); f_ru_same(); }

static void measure(const char *name, fn_t f, int n) {
  double v[1024]; f(); // 预热
  struct rusage_info_v6 r0, r1; rusage6(getpid(), &r0);
  for (int i = 0; i < n; i++) { uint64_t c0 = thread_cpu_ns(); f(); v[i] = (thread_cpu_ns() - c0) / 1e6; }
  rusage6(getpid(), &r1); double ins = (double)(r1.ri_instructions - r0.ri_instructions) / n / 1e6;
  double mn = 1e9; for (int i = 0; i < n; i++) if (v[i] < mn) mn = v[i];
  double md = median(v, n), p90 = pct(v, n, 0.9);
  printf("   %-58s min %7.3f  median %7.3f  p90 %7.3f ms  %.3f M instr -> %.3f%% / %.3f%% of one core @1 s / @2 s\n", name, mn, md, p90, ins, md / 10, md / 20);
}

// ---------- 真实采样器模拟
typedef struct { uint64_t cid; uint64_t cpu; uint64_t energy; } Prev;
static Prev PV[MAXC]; static int NPV;
static int cmp_prev(const void *a, const void *b) { uint64_t x = ((const Prev *)a)->cid, y = ((const Prev *)b)->cid; return x < y ? -1 : x > y; }
typedef struct { pid_t pid; uint64_t start; char path[256]; } PathCache; static PathCache PC[MAXP]; static int NPC; static int path_lookups;
static const char *path_for(pid_t pid) {
  struct kinfo_proc k; size_t ksz = sizeof k; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid}; uint64_t st = 0;
  if (sysctl(mib, 4, &k, &ksz, NULL, 0) == 0) st = (uint64_t)k.kp_proc.p_starttime.tv_sec * 1000000 + k.kp_proc.p_starttime.tv_usec;
  for (int i = 0; i < NPC; i++) if (PC[i].pid == pid && PC[i].start == st) return PC[i].path;
  PathCache *c = NPC < MAXP ? &PC[NPC++] : &PC[0]; c->pid = pid; c->start = st; path_lookups++; if (proc_pidpath(pid, c->path, sizeof c->path) <= 0) c->path[0] = 0; return c->path;
}
typedef struct { int idx; double cpu; } Rank; static int cmp_rank(const void *a, const void *b) { double x = ((const Rank *)a)->cpu, y = ((const Rank *)b)->cpu; return x < y ? 1 : x > y ? -1 : 0; }
static double TS[3];
static void sampler_tick(double dt, int topn, int with_libproc) { uint64_t q0 = thread_cpu_ns();
  f_list(); Rank rk[MAXC]; int nr = 0; Prev nv[MAXC]; int nn = 0;
  for (int i = 0; i < NL; i++) { if (!LI[i].tasks) continue; if (coal_cru(LI[i].cid, S[i], sizeof S[i])) continue; uint64_t cpu = coal_cpu_ticks(S[i]);
    Prev key = {LI[i].cid, 0, 0}; Prev *p = bsearch(&key, PV, NPV, sizeof *PV, cmp_prev);
    if (p && dt > 0) { rk[nr].idx = i; rk[nr].cpu = (cpu - p->cpu) * tick_to_ns() / 1e9 / dt * 100; nr++; }
    nv[nn].cid = LI[i].cid; nv[nn].cpu = cpu; nv[nn].energy = S[i][11]; nn++; }
  qsort(nv, nn, sizeof *nv, cmp_prev); memcpy(PV, nv, nn * sizeof *nv); NPV = nn;
  qsort(rk, nr, sizeof *rk, cmp_rank); uint64_t q1 = thread_cpu_ns(); TS[0] += (q1 - q0) / 1e6;
  for (int r = 0; r < topn && r < nr; r++) { pid_t buf[4096]; size_t sz = sizeof buf; if (coal_pl(LI[rk[r].idx].cid, buf, &sz)) continue; int n = sz / sizeof(pid_t);
    for (int m = 0; m < n && m < 64; m++) { struct proc_bsdshortinfo si; shortinfo(buf[m], &si); path_for(buf[m]); if (with_libproc) { struct rusage_info_v6 ri; rusage6(buf[m], &ri); } } }
  uint64_t q2 = thread_cpu_ns(); TS[1] += (q2 - q1) / 1e6; if (with_libproc) { f_listpids(); f_short(); f_ru_same(); } TS[2] += (thread_cpu_ns() - q2) / 1e6;
}
static int WARM; static double TW;
static void run_sampler(const char *name, double interval, int secs, int topn, int with_libproc, qos_class_t qos) {
  pthread_set_qos_class_self_np(qos, 0);
  struct rusage_info_v6 r0, r1; rusage6(getpid(), &r0);
  NPV = 0; NPC = 0; path_lookups = 0; uint64_t w0 = now_ns(), c0 = proc_cpu_ns(), last = 0; int ticks = 0; double tmax = 0;
  while (now_ns() - w0 < (uint64_t)secs * 1000000000ull) { if (WARM) { uint64_t s0 = now_ns(); volatile double x = 1; while (now_ns() - s0 < 3000000) x = x * 1.0000001 + 0.5; }
    uint64_t t = now_ns(), tc = thread_cpu_ns(); sampler_tick(last ? (t - last) / 1e9 : 0, topn, with_libproc); last = t; ticks++;
    double d = (thread_cpu_ns() - tc) / 1e6; if (d > tmax) tmax = d; TW += d;
    uint64_t next = w0 + (uint64_t)(ticks * interval * 1e9); uint64_t now = now_ns(); if (next > now) usleep((useconds_t)((next - now) / 1000)); }
  double wall = (now_ns() - w0) / 1e9, cpu = (proc_cpu_ns() - c0) / 1e9; rusage6(getpid(), &r1);
  double ins = (double)(r1.ri_instructions - r0.ri_instructions) / ticks, cyc = (double)(r1.ri_cycles - r0.ri_cycles) / ticks, pcyc = (double)(r1.ri_pcycles - r0.ri_pcycles) / ticks;
  double tt = ((r1.ri_user_time - r0.ri_user_time) + (r1.ri_system_time - r0.ri_system_time)) * tick_to_ns() / 1e9, pt = ((r1.ri_user_ptime - r0.ri_user_ptime) + (r1.ri_system_ptime - r0.ri_system_ptime)) * tick_to_ns() / 1e9;
  double mj = (r1.ri_energy_nj - r0.ri_energy_nj) / 1e6 / ticks;
  printf("   %-44s %2d ticks/%.0f s: %.2f ms/tick (max %.2f) = %.3f%% of one core | %.2f M instr/tick, %.0f MHz eff, perflevel0 share %.0f%%, %.3f mJ/tick | scan %.2f resolve %.2f libproc %.2f ms/tick; path lookups %d\n",
         name, ticks, wall, cpu * 1e3 / ticks, tmax, 100 * cpu / wall, ins / 1e6, tt > 0 ? cyc / tt / 1e6 : 0, tt > 0 ? 100 * pt / tt : 0, mj, TS[0] / ticks, TS[1] / ticks, TS[2] / ticks, path_lookups); (void)pcyc;
  if (WARM) printf("      (warm variant: 3 ms busy spin before each tick, excluded from the per-tick figures below; Top N part alone = %.2f ms/tick = %.3f%% of one core)\n", TW / ticks, TW / ticks / (interval * 10));
  TS[0] = TS[1] = TS[2] = 0; TW = 0;
}

int main(int argc, char **argv) {
  int n = argc > 1 ? atoi(argv[1]) : 60, secs = argc > 2 ? atoi(argv[2]) : 20; if (n > 1024) n = 1024;
  print_machine(); coal_init(); ME = getuid(); f_list(); f_listpids(); f_short();
  int live = 0; for (int i = 0; i < NL; i++) live += LI[i].tasks > 0; int same = 0; for (int i = 0; i < NP; i++) same += SIok[i] && SI[i].pbsi_uid == ME;
  printf("# sizes: coalitions %d (live %d), pids %d (same uid %d); per item thread CPU time, %d repetitions\n", NL, live, NP, same, n);
  printf("A) components:\n");
  measure("proc_listcoalitions", f_list, n);
  measure("coalition_info_resource_usage x all listed", f_cru_all, n);
  measure("coalition_info_resource_usage x live (tasks>0)", f_cru_live, n);
  measure("coalition_info_pid_list x live", f_pl_all, n);
  measure("proc_listallpids", f_listpids, n);
  measure("PROC_PIDT_SHORTBSDINFO x all pids", f_short, n);
  measure("proc_pid_rusage(V6) x all pids (foreign -> EPERM)", f_ru_all, n);
  measure("proc_pid_rusage(V6) x same-uid pids only", f_ru_same, n);
  measure("proc_pidpath x all pids (uncached)", f_path, n);
  measure("sysctl KERN_PROC_ALL (one call, all kinfo_proc)", f_kinfo_all, n);
  measure("PROC_PIDCOALITIONINFO x all pids", f_pidcoal, n);
  measure("responsibility_get_pid_responsible_for_pid x same-uid", f_resp, n);
  printf("B) tick compositions:\n");
  measure("coalition-only tick: list + cru(live)", f_tick_coal_min, n);
  measure("full tick: list + cru + pid_list all + pids + short + rusage same", f_tick_full, n);
  printf("C) simulated sampler (top 10 coalitions resolved each tick, path cache keyed by pid+start time):\n");
  run_sampler("coalition only, 1 s, QoS default", 1.0, secs, 10, 0, QOS_CLASS_DEFAULT);
  run_sampler("coalition only, 2 s, QoS default", 2.0, secs, 10, 0, QOS_CLASS_DEFAULT);
  run_sampler("coalition + same-uid libproc, 1 s, default", 1.0, secs, 10, 1, QOS_CLASS_DEFAULT);
  run_sampler("coalition + same-uid libproc, 2 s, default", 2.0, secs, 10, 1, QOS_CLASS_DEFAULT);
  run_sampler("coalition only, 1 s, QoS utility", 1.0, secs, 10, 0, QOS_CLASS_UTILITY);
  run_sampler("coalition only, 1 s, QoS user-initiated", 1.0, secs, 10, 0, QOS_CLASS_USER_INITIATED);
  run_sampler("coalition only, 1 s, QoS background", 1.0, secs, 10, 0, QOS_CLASS_BACKGROUND);
  printf("D) merged-tick approximation (tick already awake: 3 ms spin first, only the Top N part is timed):\n"); WARM = 1;
  run_sampler("warm: coalition only, 1 s, default", 1.0, secs, 10, 0, QOS_CLASS_DEFAULT);
  run_sampler("warm: coalition + same-uid libproc, 1 s", 1.0, secs, 10, 1, QOS_CLASS_DEFAULT);
  return 0;
}
