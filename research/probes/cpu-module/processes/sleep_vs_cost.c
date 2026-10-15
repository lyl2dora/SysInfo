// sleep_vs_cost.c - 同一段 coalition 扫描（list + 全部 live coalition 的 resource usage）在不同「前置睡眠」后的线程 CPU 时间，
// 用来解释「紧循环 0.5 ms / 周期采样 6–8 ms」的差距（冷缓存 / 核心降频 / 被调度到低档核）。只读。
// build: xcrun clang -O1 -o sleep_vs_cost sleep_vs_cost.c
#include "coal.h"
#include <pthread.h>
#include <pthread/qos.h>
static double scan(void) { struct coal_listent *li; uint64_t c0 = thread_cpu_ns(); int n = coal_list(&li); uint64_t s[COAL_SLOTS];
  for (int i = 0; i < n; i++) if (li[i].tasks) coal_cru(li[i].cid, s, sizeof s); double d = (thread_cpu_ns() - c0) / 1e6; free(li); return d; }
int main(void) { print_machine(); coal_init(); int sl[] = {0, 1, 10, 100, 500, 1000}; qos_class_t qs[] = {QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_DEFAULT, QOS_CLASS_UTILITY};
  const char *qn[] = {"user-interactive", "default", "utility"};
  for (int q = 0; q < 3; q++) { pthread_set_qos_class_self_np(qs[q], 0);
    for (int k = 0; k < 6; k++) { double v[12]; int n = sl[k] >= 500 ? 6 : 12; for (int i = 0; i < n; i++) { if (sl[k]) usleep(sl[k] * 1000); v[i] = scan(); }
      struct rusage_info_v6 r; rusage6(getpid(), &r);
      printf("QoS %-17s sleep %4d ms before scan: median %.2f ms, min %.2f, max %.2f (n=%d)\n", qn[q], sl[k], median(v, n), pct(v, n, 0), pct(v, n, 1), n); } }
  return 0; }
