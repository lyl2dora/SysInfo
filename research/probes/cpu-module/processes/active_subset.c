// active_subset.c - 周期采样中每个窗口里「有 CPU 增量」的 coalition 有多少；只读这部分时冷开销多少。
// 用来评估「全量扫描降频 + 活跃子集高频」的分层方案。只读。
// build: xcrun clang -O1 -o active_subset active_subset.c
#include "coal.h"
#define MAXC 4096
static uint64_t prev[MAXC][2]; static int np;   // cid, cpu
static uint64_t getprev(uint64_t cid) { for (int i = 0; i < np; i++) if (prev[i][0] == cid) return prev[i][1]; return UINT64_MAX; }
int main(int argc, char **argv) { int ticks = argc > 1 ? atoi(argv[1]) : 10; double iv = argc > 2 ? atof(argv[2]) : 1.0; print_machine(); coal_init();
  static uint64_t active[MAXC]; int nact = 0; double full[64], sub[64]; int nf = 0, ns = 0;
  for (int t = 0; t < ticks; t++) { usleep((useconds_t)(iv * 1e6));
    if (t % 2 == 0 || nact == 0) { // 全量
      uint64_t c0 = thread_cpu_ns(); struct coal_listent *li; int n = coal_list(&li); uint64_t s[COAL_SLOTS]; int live = 0, a1 = 0, a01 = 0, a0 = 0; nact = 0;
      static uint64_t cur[MAXC][2]; int nc = 0;
      for (int i = 0; i < n; i++) { if (!li[i].tasks) continue; live++; if (coal_cru(li[i].cid, s, sizeof s)) continue; uint64_t c = coal_cpu_ticks(s); uint64_t p = getprev(li[i].cid);
        cur[nc][0] = li[i].cid; cur[nc][1] = c; nc++;
        if (p != UINT64_MAX) { double pctv = (c - p) * tick_to_ns() / 1e9 / iv * 100; if (c > p) { a0++; active[nact++] = li[i].cid; } if (pctv >= 0.1) a01++; if (pctv >= 1) a1++; } else active[nact++] = li[i].cid; }
      memcpy(prev, cur, nc * sizeof cur[0]); np = nc; free(li); double d = (thread_cpu_ns() - c0) / 1e6; if (t) full[nf++] = d;
      if (t) printf("tick %2d FULL   live %d: active(dCPU>0) %d, >=0.1%% %d, >=1%% %d; cost %.2f ms\n", t, live, a0, a01, a1, d);
    } else { // 只读上次活跃的子集
      uint64_t c0 = thread_cpu_ns(); uint64_t s[COAL_SLOTS]; int ok = 0; for (int i = 0; i < nact; i++) ok += coal_cru(active[i], s, sizeof s) == 0; double d = (thread_cpu_ns() - c0) / 1e6; sub[ns++] = d;
      printf("tick %2d SUBSET %d coalitions (ok %d); cost %.2f ms\n", t, nact, ok, d); } }
  printf("median full %.2f ms, median subset %.2f ms (interval %.1f s)\n", median(full, nf), median(sub, ns), iv); return 0; }
