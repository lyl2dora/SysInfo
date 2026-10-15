// sk_churn.c - 复核「coalition 窗口增量能精确计入窗口内已退出的短命子进程」「slot 3 窗口增量少算」「各 QoS（含 background）都计入槽 24–30」。
// 真值不用 top：每个子进程在退出前用 proc_pid_rusage(self) 自报 CPU 时间，经管道交给父进程。
// 期望值 = Σ 子进程自报 + Σ 窗口内一直存活的同 uid 成员的 Δ(ri_user+ri_system)；残差 = Δcoalition − 期望值。
// 负载：N 个子进程、每个自旋 ms 毫秒 CPU，最多 C 个并发，QoS 轮换 UI/default/utility/background。总 CPU = N*ms（默认 160*8 ms ≈ 1.3 s，墙钟 < 5 s）。
// 子进程自旋结束后读一次 rusage，睡 20 ms 再读一次，用来检查能耗是否要等上下文切换才结算。
// 用法：sk_churn [N=160] [ms=8] [C=4]    build: xcrun clang -O1 -o sk_churn sk_churn.c
#include "sk.h"
#include <spawn.h>
#include <sys/wait.h>
#include <pthread/qos.h>
extern char **environ;
struct rep { pid_t pid; int qos; uint64_t cpu, ptime, energy, cpu2, energy2; };

static int child(int ms, int q, int fd) {
  qos_class_t qs[] = {QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_DEFAULT, QOS_CLASS_UTILITY, QOS_CLASS_BACKGROUND};
  pthread_set_qos_class_self_np(qs[q & 3], 0);
  volatile double x = 1; while (sk_pcpu() < (uint64_t)ms * 1000000ull) x = x * 1.0000001 + 0.5;
  struct rusage_info_v6 r, r2; proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r);
  usleep(20000); proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r2);   // 睡 20 ms（发生上下文切换）后再读一次，看能耗是否「补结算」
  struct rep p = {getpid(), q, r.ri_user_time + r.ri_system_time, r.ri_user_ptime + r.ri_system_ptime, r.ri_energy_nj, r2.ri_user_time + r2.ri_system_time, r2.ri_energy_nj};
  write(fd, &p, sizeof p); _exit(0);
}

int main(int argc, char **argv) {
  if (argc >= 5 && !strcmp(argv[1], "child")) return child(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
  int N = argc > 1 ? atoi(argv[1]) : 160, ms = argc > 2 ? atoi(argv[2]) : 8, C = argc > 3 ? atoi(argv[3]) : 4;
  sk_machine(); if (!sk_init()) { printf("symbols missing\n"); return 1; }
  uint64_t cid = sk_cid_of(getpid()); pid_t mem[4096]; int nm = sk_members(cid, mem, 4096);
  printf("own coalition %llu, %d live members at start; load: N=%d children x %d ms CPU, <=%d concurrent, QoS rotating UI/default/utility/background\n", cid, nm, N, ms, C);
  static struct rusage_info_v6 r0[4096], r1[4096]; int ok0[4096];
  for (int i = 0; i < nm; i++) ok0[i] = proc_pid_rusage(mem[i], RUSAGE_INFO_V6, (rusage_info_t *)&r0[i]) == 0;
  uint64_t s0[SKS], s1[SKS]; sk_cru(cid, s0, sizeof s0); uint64_t w0 = sk_now();
  int pfd[2]; pipe(pfd); char exe[PROC_PIDPATHINFO_MAXSIZE]; proc_pidpath(getpid(), exe, sizeof exe);
  int running = 0, started = 0; struct rep reps[4096]; int nrep = 0;
  while (started < N || running > 0) {
    while (started < N && running < C) {
      char a2[16], a3[16], a4[16]; snprintf(a2, sizeof a2, "%d", ms); snprintf(a3, sizeof a3, "%d", started & 3); snprintf(a4, sizeof a4, "%d", pfd[1]);
      char *av[] = {exe, "child", a2, a3, a4, NULL}; pid_t p; if (posix_spawn(&p, exe, NULL, NULL, av, environ) == 0) { running++; started++; } else { perror("spawn"); started++; } }
    int st; pid_t w = wait(&st); if (w > 0) running--; }
  close(pfd[1]); struct rep rp; while (read(pfd[0], &rp, sizeof rp) == sizeof rp && nrep < 4096) reps[nrep++] = rp;
  // 结束快照：先成员，再 coalition，顺序与开始时相同
  int ok1[4096]; for (int i = 0; i < nm; i++) ok1[i] = proc_pid_rusage(mem[i], RUSAGE_INFO_V6, (rusage_info_t *)&r1[i]) == 0;
  sk_cru(cid, s1, sizeof s1); double wall = (sk_now() - w0) / 1e9;
  double k = sk_tb() / 1e6;  // tick -> ms
  double live = 0; int nlive = 0, nforeign = 0; for (int i = 0; i < nm; i++) { if (ok0[i] && ok1[i]) { live += ((r1[i].ri_user_time + r1[i].ri_system_time) - (r0[i].ri_user_time + r0[i].ri_system_time)) * k; nlive++; } else nforeign++; }
  double kids = 0, kidsq[4] = {0}, kidp = 0, kide = 0, kids2 = 0, kide2 = 0; for (int i = 0; i < nrep; i++) { kids += reps[i].cpu * k; kids2 += reps[i].cpu2 * k; kide2 += reps[i].energy2 / 1e6; kidsq[reps[i].qos] += reps[i].cpu * k; kidp += reps[i].ptime * k; kide += reps[i].energy / 1e6; }
  double deq = (sk_eqos(s1) - sk_eqos(s0)) * k, d3 = (s1[3] - s0[3]) * k, d22 = (s1[22] - s0[22]) * k, d11 = (s1[11] - s0[11]) / 1e6;
  long dstart = (long)(s1[0] - s0[0]), dexit = (long)(s1[1] - s0[1]);
  double exp_ = kids + live;
  printf("window %.2f s; tasks_started +%ld (children %d), tasks_exited +%ld; child reports received %d; members readable by libproc %d, unreadable %d\n", wall, dstart, N, dexit, nrep, nlive, nforeign);
  printf("children self-reported CPU: total %.1f ms  [UI %.1f, default %.1f, utility %.1f, background %.1f]; live members' libproc delta %.1f ms\n", kids, kidsq[0], kidsq[1], kidsq[2], kidsq[3], live);
  printf("eqos per bucket delta (ms):"); for (int i = 24; i <= 30; i++) printf(" [%d]%.1f", i - 24, (s1[i] - s0[i]) * k); printf("\n");
  printf("coalition d(eqos 24..30) = %.1f ms; expected %.1f ms; residual %+.1f ms (%+.2f%%); per extra task %+.3f ms\n", deq, exp_, deq - exp_, 100 * (deq - exp_) / exp_, (dstart - N) >= 0 && dstart ? (deq - exp_) / dstart : 0);
  printf("coalition d(slot 3 ledger) = %.1f ms -> slot3/eqos = %.3f\n", d3, deq ? d3 / deq : 0);
  printf("coalition d(slot 22 ptime) = %.1f ms vs children ptime %.1f ms (+live not tracked); d(slot 11) = %.2f mJ vs children energy %.2f mJ\n", d22, kidp, d11, kide);
  printf("child self-read right after spin vs 20 ms later (after blocking): CPU %.1f -> %.1f ms, energy %.2f -> %.2f mJ\n", kids, kids2, kide, kide2);
  printf("per-process view (libproc on pids alive at both ends) would show %.1f ms of %.1f ms => misses %.1f%%\n", live, deq, deq ? 100 * (1 - live / deq) : 0);
  return 0;
}
