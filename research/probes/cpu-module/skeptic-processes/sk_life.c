// sk_life.c - 复核「空 coalition（tasks==0）仍可读，所以窗口内退出的应用也能补上」。被动观察 S 秒（默认 60），不制造负载。
// 每 100 ms 调一次 proc_listcoalitions（很便宜）；新出现的、tasks 有变化的 coalition 立即读 resource_usage；
// 同时模拟 1 s / 2 s 采样器：在整秒边界读全部 live coalition。统计：
//  a) 观察期内出现又消失的 coalition：寿命、消失前 tasks 是否先变 0、它们的 CPU 有多少落在「最后一次采样器读取」之后（= 采样器漏掉的）；
//  b) tasks 变 0 的 coalition 多久后从列表里消失（或到结束仍在）。
// 用法：sk_life [S=60]    build: xcrun clang -O1 -o sk_life sk_life.c
#include "sk.h"
#define MAXT 8192
typedef struct { uint64_t cid; double born, gone, zero_at; uint32_t tasks; int alive, born_in_obs; uint64_t first_cpu, last_cpu, s1_cpu, s2_cpu; int s1_seen, s2_seen; } T;
static T tr[MAXT]; static int nt;
static T *find(uint64_t cid) { for (int i = 0; i < nt; i++) if (tr[i].cid == cid) return &tr[i]; return NULL; }
static uint64_t rd(uint64_t cid, int *ok) { uint64_t s[SKS]; *ok = sk_cru(cid, s, sizeof s) == 0; return *ok ? sk_eqos(s) : 0; }
int main(int argc, char **argv) {
  int S = argc > 1 ? atoi(argv[1]) : 60; sk_machine(); if (!sk_init()) return 1; double k = sk_tb() / 1e6; uint64_t w0 = sk_now(); int polls = 0, sec_prev = -1;
  while (sk_now() - w0 < (uint64_t)S * 1000000000ull) {
    double t = (sk_now() - w0) / 1e9; struct sk_ent *li; int n = sk_list(&li); polls++; int sec = (int)t;
    for (int i = 0; i < nt; i++) tr[i].alive = 0;
    for (int i = 0; i < n; i++) { T *x = find(li[i].cid); int ok;
      if (!x && nt < MAXT) { x = &tr[nt++]; memset(x, 0, sizeof *x); x->cid = li[i].cid; x->born = t; x->born_in_obs = polls > 1; x->gone = -1; x->zero_at = -1; x->tasks = li[i].tasks; x->first_cpu = x->last_cpu = rd(x->cid, &ok); }
      else if (x && x->tasks != li[i].tasks) { if (li[i].tasks == 0 && x->zero_at < 0) x->zero_at = t; if (li[i].tasks) x->zero_at = -1; x->tasks = li[i].tasks; uint64_t c = rd(x->cid, &ok); if (ok) x->last_cpu = c; }
      if (x) x->alive = 1; }
    if (sec != sec_prev) { // 整秒：模拟 1 s 采样器（每秒）与 2 s 采样器（偶数秒），读全部 live
      for (int i = 0; i < n; i++) { if (!li[i].tasks) continue; T *x = find(li[i].cid); if (!x) continue; int ok; uint64_t c = rd(x->cid, &ok); if (!ok) continue; x->last_cpu = c; x->s1_cpu = c; x->s1_seen = 1; if (sec % 2 == 0) { x->s2_cpu = c; x->s2_seen = 1; } }
      sec_prev = sec; }
    for (int i = 0; i < nt; i++) if (!tr[i].alive && tr[i].gone < 0) tr[i].gone = t;
    free(li); usleep(100000); }
  int born = 0, died = 0, both = 0, died_zero_first = 0, zero_now = 0, zero_reaped = 0; double miss1 = 0, miss2 = 0, tot_dead = 0, life[MAXT], lag[MAXT]; int nl = 0, ng = 0;
  for (int i = 0; i < nt; i++) { T *x = &tr[i]; born += x->born_in_obs; if (x->gone >= 0) { died++; if (x->zero_at >= 0) { died_zero_first++; lag[ng++] = x->gone - x->zero_at; } }
    if (x->born_in_obs && x->gone >= 0) { both++; life[nl++] = x->gone - x->born; }
    if (x->gone >= 0) { double c = (x->last_cpu - x->first_cpu) * k; tot_dead += c; miss1 += (x->last_cpu - (x->s1_seen ? x->s1_cpu : x->first_cpu)) * k; miss2 += (x->last_cpu - (x->s2_seen ? x->s2_cpu : x->first_cpu)) * k; }
    if (x->gone < 0 && x->tasks == 0) zero_now++; if (x->zero_at >= 0 && x->gone >= 0) zero_reaped++; }
  printf("observed %d s, %d polls; coalitions tracked %d; born during observation %d; disappeared %d (born+disappeared %d)\n", S, polls, nt, born, died, both);
  if (nl) printf("lifetime of born+disappeared coalitions: median %.2f s, min %.2f, max %.2f\n", sk_med(life, nl), life[0], life[nl - 1]);
  printf("disappeared coalitions seen with tasks==0 before vanishing: %d/%d; delay tasks==0 -> vanished: median %.2f s (n=%d)\n", died_zero_first, died, ng ? sk_med(lag, ng) : 0, ng);
  printf("coalitions with tasks==0 still listed at end: %d\n", zero_now);
  printf("CPU of disappeared coalitions seen by 100 ms poller: %.1f ms; of which after the last 1 s sampler read: %.1f ms, after the last 2 s sampler read: %.1f ms\n", tot_dead, miss1, miss2);
  for (int i = 0, shown = 0; i < nt && shown < 12; i++) { T *x = &tr[i]; if (x->gone < 0) continue; shown++;
    printf("   cid %-6llu born %6.2f%s gone %6.2f zero_at %6.2f cpu %.1f ms (after last 1 s read %.1f)\n", x->cid, x->born, x->born_in_obs ? "" : "(pre)", x->gone, x->zero_at, (x->last_cpu - x->first_cpu) * k, (x->last_cpu - (x->s1_seen ? x->s1_cpu : x->first_cpu)) * k); }
  return 0; }
