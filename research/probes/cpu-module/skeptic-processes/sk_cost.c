// sk_cost.c - 独立复核 Top N 采样开销（对方：M5 0.70%@1 s / 0.39%@2 s；M2 0.83% / 0.42%；分层扫描约 0.4%@1 s）。
// 与 SamplingEngine 同构：DispatchSourceTimer 挂在 QoS utility 的串行队列上，leeway 100 ms。
// 每 tick：proc_listcoalitions + 所有 live coalition 的 resource_usage + 排序 + 前 10 名 pid_list 与名称（按 pid+uniqueid 缓存 proc_pidpath）。
// 开销口径：本进程 getrusage(RUSAGE_SELF) 的 user+sys 增量 / 墙钟（= Activity Monitor 口径的单核占比），同时给 tick 内线程 CPU 时间。
// 模式：full（每 tick 全量）/ tier2（每 2 tick 一次全量，其余只读上一轮有增量的 + 新 cid）/ tier5（每 5 tick 全量）。
// 另有 B 部分：冷态逐 coalition 计时，看开销是否集中在少数 coalition。
// 不制造负载。用法：sk_cost [secs=30] [rounds=3]    build: xcrun clang -O1 -o sk_cost sk_cost.c
#include "sk.h"
#include <dispatch/dispatch.h>
#include <sys/time.h>
#define MAXC 4096
typedef struct { uint64_t cid, cpu; int seen; } Prev;
static Prev PV[MAXC]; static int NPV; static uint64_t ACT[MAXC]; static int NACT;
typedef struct { pid_t pid; uint64_t uniq; char name[64]; } NC; static NC NCACHE[8192]; static int NNC, name_miss;
static int cmpcid(const void *a, const void *b) { uint64_t x = ((const Prev *)a)->cid, y = ((const Prev *)b)->cid; return (x > y) - (x < y); }
// PROC_PIDUNIQIDENTIFIERINFO (17) 与其结构体在公开 SDK 里是私有的（xnu sys/proc_info_private.h），这里按 xnu 布局本地定义
struct sk_uniq { uint8_t uuid[16]; uint64_t uniqueid, puniqueid; int32_t idversion; uint32_t r2; uint64_t r3, r4; };
static uint64_t uniq_of(pid_t p) { struct sk_uniq u; if (proc_pidinfo(p, 17, 0, &u, sizeof u) == sizeof u) return u.uniqueid; return 0; }
static const char *name_of(pid_t p) { uint64_t u = uniq_of(p); for (int i = 0; i < NNC; i++) if (NCACHE[i].pid == p && NCACHE[i].uniq == u) return NCACHE[i].name;
  NC *c = &NCACHE[NNC < 8192 ? NNC++ : 0]; c->pid = p; c->uniq = u; sk_name(p, c->name, sizeof c->name); name_miss++; return c->name; }
typedef struct { double cpu; uint64_t cid; } Rk; static int cmprk(const void *a, const void *b) { double x = ((const Rk *)a)->cpu, y = ((const Rk *)b)->cpu; return (x < y) - (x > y); }
static int MODE, TICK; static uint64_t LASTT; static double TICKCPU[256]; static int NT; static int NREAD;
static void tick(void) {
  uint64_t c0 = sk_tcpu(), t = sk_now(); double dt = LASTT ? (t - LASTT) / 1e9 : 0; LASTT = t;
  struct sk_ent *li; int n = sk_list(&li); int full = MODE == 0 || TICK % MODE == 0 || NACT == 0; static Rk rk[MAXC]; int nr = 0; static Prev nv[MAXC]; int nn = 0, nact = 0; static uint64_t act[MAXC];
  for (int i = 0; i < n; i++) { if (!li[i].tasks) continue; Prev key = {li[i].cid, 0, 0}; Prev *p = NPV ? bsearch(&key, PV, NPV, sizeof *PV, cmpcid) : NULL;
    int want = full || !p; if (!want) { for (int a = 0; a < NACT; a++) if (ACT[a] == li[i].cid) { want = 1; break; } }
    uint64_t cpu; if (want) { uint64_t s[SKS]; if (sk_cru(li[i].cid, s, sizeof s)) continue; cpu = sk_eqos(s); NREAD++; } else cpu = p->cpu;
    if (p && dt > 0 && cpu > p->cpu) { rk[nr].cpu = (cpu - p->cpu) * sk_tb() / 1e9 / dt * 100; rk[nr].cid = li[i].cid; nr++; act[nact++] = li[i].cid; } else if (!p) act[nact++] = li[i].cid;
    nv[nn].cid = li[i].cid; nv[nn].cpu = cpu; nn++; }
  free(li); qsort(nv, nn, sizeof *nv, cmpcid); memcpy(PV, nv, nn * sizeof *nv); NPV = nn; memcpy(ACT, act, nact * sizeof *act); NACT = nact;
  qsort(rk, nr, sizeof *rk, cmprk); for (int r = 0; r < 10 && r < nr; r++) { pid_t m[256]; int k = sk_members(rk[r].cid, m, 256); for (int j = 0; j < k && j < 16; j++) (void)name_of(m[j]); }
  if (NT < 256) TICKCPU[NT++] = (sk_tcpu() - c0) / 1e6; TICK++; }
static double self_cpu(void) { struct rusage r; getrusage(RUSAGE_SELF, &r); return r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6 + r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6; }
static double run(int mode, double iv, int secs, double *tick_med) {
  MODE = mode; TICK = 0; LASTT = 0; NPV = 0; NACT = 0; NT = 0; NNC = 0; name_miss = 0; NREAD = 0;
  dispatch_queue_t q = dispatch_queue_create_with_target("sk.sampling", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0), NULL);
  dispatch_source_t tm = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_timer(tm, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(iv * 1e9)), (uint64_t)(iv * 1e9), 100000000ull);
  dispatch_source_set_event_handler(tm, ^{ tick(); });
  double c0 = self_cpu(); uint64_t w0 = sk_now(); dispatch_resume(tm); sleep(secs); dispatch_source_cancel(tm); dispatch_sync(q, ^{}); double c1 = self_cpu(), w = (sk_now() - w0) / 1e9;
  double v[256]; memcpy(v, TICKCPU, NT * sizeof *v); *tick_med = sk_med(v, NT); return 100 * (c1 - c0) / w; }
int main(int argc, char **argv) {
  int secs = argc > 1 ? atoi(argv[1]) : 30, rounds = argc > 2 ? atoi(argv[2]) : 3; sk_machine(); if (!sk_init()) return 1;
  struct sk_ent *li; int n = sk_list(&li); int live = 0; for (int i = 0; i < n; i++) live += li[i].tasks > 0;
  int fu = 0, fn = 0; pid_t pids[16384]; int np = proc_listallpids(pids, sizeof pids) ; for (int i = 0; i < np; i++) { fn++; fu += uniq_of(pids[i]) != 0; }
  printf("coalitions %d (live %d); PROC_PIDUNIQIDENTIFIERINFO works for %d/%d pids (usable as name-cache key for foreign pids)\n", n, live, fu, fn);
  // A) 开销：full@1, full@2, tier2@1, tier5@1，交替跑 rounds 轮
  const char *nm[] = {"full @1 s", "full @2 s", "tier2 @1 s", "tier5 @1 s"}; int md[] = {0, 0, 2, 5}; double iv[] = {1, 2, 1, 1};
  double res[4][8], tk[4][8];
  for (int r = 0; r < rounds; r++) for (int m = 0; m < 4; m++) { res[m][r] = run(md[m], iv[m], secs, &tk[m][r]);
    double la[3]; getloadavg(la, 3); printf("   round %d %-11s: process CPU %.3f%% of one core; median tick %.2f ms thread CPU; coalition reads/tick %.0f; loadavg %.2f\n", r + 1, nm[m], res[m][r], tk[m][r], (double)NREAD / (TICK ? TICK : 1), la[0]); fflush(stdout); }
  printf("A) medians over %d rounds x %d s:\n", rounds, secs); for (int m = 0; m < 4; m++) { double a[8], b[8]; memcpy(a, res[m], sizeof a); memcpy(b, tk[m], sizeof b); printf("   %-11s %.3f%% of one core (median tick %.2f ms)\n", nm[m], sk_med(a, rounds), sk_med(b, rounds)); }
  // B) 冷态逐 coalition 计时：睡 1 s 后逐个读，重复 5 次，取每个 cid 的中位数
  static double per[MAXC][5]; static uint64_t cids[MAXC]; static int tasks[MAXC]; int nc = 0; for (int i = 0; i < n && nc < MAXC; i++) if (li[i].tasks) { cids[nc] = li[i].cid; tasks[nc] = li[i].tasks; nc++; }
  for (int r = 0; r < 5; r++) { sleep(1); for (int i = 0; i < nc; i++) { uint64_t s[SKS]; uint64_t c0 = sk_tcpu(); sk_cru(cids[i], s, sizeof s); per[i][r] = (sk_tcpu() - c0) / 1e3; } }
  static double med[MAXC]; double tot = 0; for (int i = 0; i < nc; i++) { double v[5]; memcpy(v, per[i], sizeof v); med[i] = sk_med(v, 5); tot += med[i]; }
  static int idx[MAXC]; for (int i = 0; i < nc; i++) idx[i] = i; for (int a = 0; a < nc; a++) for (int b = a + 1; b < nc; b++) if (med[idx[b]] > med[idx[a]]) { int t = idx[a]; idx[a] = idx[b]; idx[b] = t; }
  double top10 = 0; for (int i = 0; i < 10 && i < nc; i++) top10 += med[idx[i]]; double m1 = 0, mm = 0; int n1 = 0, nmm = 0; for (int i = 0; i < nc; i++) { if (tasks[i] == 1) { m1 += med[i]; n1++; } else { mm += med[i]; nmm++; } }
  double all[MAXC]; memcpy(all, med, nc * sizeof *all);
  printf("B) cold per-coalition cost (after 1 s sleep, median of 5): total %.2f ms over %d; median %.1f us, p90 %.1f us; top-10 share %.0f%%; mean single-member %.1f us, multi-member %.1f us\n",
         tot / 1000, nc, sk_med(all, nc), all[(int)(0.9 * (nc - 1))], 100 * top10 / tot, n1 ? m1 / n1 : 0, nmm ? mm / nmm : 0);
  for (int i = 0; i < 8 && i < nc; i++) { int j = idx[i]; pid_t m[64]; int k = sk_members(cids[j], m, 64); char b[64]; printf("   %7.1f us  cid %-6llu tasks %-3d %s\n", med[j], cids[j], tasks[j], k > 0 ? sk_name(m[0], b, sizeof b) : "?"); }
  return 0; }
