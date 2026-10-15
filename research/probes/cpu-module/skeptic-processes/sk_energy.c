// sk_energy.c - 复核「slot 11 / ri_energy_nj 可作每应用 CPU 能耗」的时效性：一直在跑、不被切换的线程，其能耗是否实时计入？
// 做法：工作线程按指定 QoS 自旋 T 秒；观察线程每 100 ms 读一次本进程 rusage（CPU 时间、能耗）与本 coalition 的 slot 11 / 槽 24–30。
// 如果能耗只在上下文切换时结算，会看到 CPU 时间平滑增长而能耗停滞或跳变；结束时（工作线程退出后）一次性补齐。
// 负载：1 个线程自旋 T 秒（默认 3 s）。用法：sk_energy [T=3] [qos: ui|bg] [yield_every_ms=0]
// build: xcrun clang -O1 -o sk_energy sk_energy.c
#include "sk.h"
#include <pthread.h>
#include <pthread/qos.h>
static volatile int stop; static double T = 3; static int yield_ms = 0; static qos_class_t Q = QOS_CLASS_USER_INTERACTIVE;
static void *work(void *a) { (void)a; pthread_set_qos_class_self_np(Q, 0); volatile double x = 1; uint64_t last = sk_now();
  while (!stop) { x = x * 1.0000001 + 0.5; if (yield_ms && sk_now() - last > (uint64_t)yield_ms * 1000000) { usleep(50); last = sk_now(); } } return 0; }
int main(int argc, char **argv) {
  T = argc > 1 ? atof(argv[1]) : 3; if (argc > 2 && !strcmp(argv[2], "bg")) Q = QOS_CLASS_BACKGROUND; yield_ms = argc > 3 ? atoi(argv[3]) : 0;
  sk_machine(); sk_init(); uint64_t cid = sk_cid_of(getpid()); pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  printf("worker QoS %s, spin %.1f s, %s; observer every 100 ms (own rusage + own coalition %llu)\n", Q == QOS_CLASS_BACKGROUND ? "background" : "user-interactive", T, yield_ms ? "worker sleeps 50 us every N ms" : "worker never blocks", cid);
  struct rusage_info_v6 r0, r; uint64_t s0[SKS], s[SKS]; proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r0); sk_cru(cid, s0, sizeof s0);
  pthread_t th; pthread_create(&th, 0, work, 0); uint64_t w0 = sk_now(); double k = sk_tb() / 1e6;
  printf("   t(s)  self_cpu_ms  self_energy_mJ  self_W(avg)  coal_eqos_ms  coal_slot11_mJ\n");
  int i = 0; while (sk_now() - w0 < T * 1e9) { usleep(100000); i++;
    proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r); sk_cru(cid, s, sizeof s);
    double cpu = ((r.ri_user_time + r.ri_system_time) - (r0.ri_user_time + r0.ri_system_time)) * k, e = (r.ri_energy_nj - r0.ri_energy_nj) / 1e6;
    if (i % 3 == 0 || i < 4) printf("  %5.2f  %10.1f  %14.2f  %10.3f  %12.1f  %14.2f\n", (sk_now() - w0) / 1e9, cpu, e, cpu ? e / cpu : 0, (sk_eqos(s) - sk_eqos(s0)) * k, (s[11] - s0[11]) / 1e6); }
  stop = 1; pthread_join(th, 0);
  proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r); sk_cru(cid, s, sizeof s);
  double cpu = ((r.ri_user_time + r.ri_system_time) - (r0.ri_user_time + r0.ri_system_time)) * k, e = (r.ri_energy_nj - r0.ri_energy_nj) / 1e6;
  printf("after join: self cpu %.1f ms, energy %.2f mJ (avg %.3f W); coalition eqos %.1f ms, slot11 %.2f mJ\n", cpu, e, cpu ? e / cpu : 0, (sk_eqos(s) - sk_eqos(s0)) * k, (s[11] - s0[11]) / 1e6);
  return 0; }
