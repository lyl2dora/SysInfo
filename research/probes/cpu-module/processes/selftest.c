// selftest.c - 「进程 Top N」数据源的启动自检原型（D05）：不依赖芯片、不写死 cid，两台机器跑同一份逻辑。只读。
//   S1 符号：proc_listcoalitions / coalition_info_pid_list / coalition_info_resource_usage 均可 dlsym
//   S2 本进程：PROC_PIDCOALITIONINFO 给出 cid，且本 pid 出现在该 cid 的 pid_list 里
//   S3 布局：给 512 字节缓冲（两种填充图样），恰好写出 400 字节（50 槽）；slot 23 (eqos_len) == 7
//   S4 语义（水平量，瞬时）：同 uid、只有 1 个 live 成员且 tasks_started−tasks_exited == 1 的 coalition 中，
//      slot 40 == ri_phys_footprint、slot 49 == ri_pageins、slot 11 == ri_energy_nj、slot 22 == ri_*_ptime 之和 的「逐位相等」比例
//   S5 语义（增量）：本线程自旋 60 ms，本 coalition 的 Δeqos 与 Δslot11 应 ≥ 本进程 Δ(user+system) 与 Δri_energy_nj 的 95%，
//      且单成员时应逐位相等（LaunchServices 启动的 app 通常就是单成员）
// 输出每项 PASS/FAIL、判据和耗时。
// build: xcrun clang -O1 -o selftest selftest.c
#include "coal.h"
#include <math.h>

static int check(const char *name, int pass, const char *detail) { printf("  %-4s %-60s %s\n", pass ? "PASS" : "FAIL", name, detail); return pass; }

int main(void) {
  print_machine(); uint64_t w0 = now_ns(), c0 = thread_cpu_ns(); char d[256]; int all = 1;
  // S1
  int s1 = coal_init(); snprintf(d, sizeof d, "cru=%p pl=%p lc=%p", (void *)coal_cru, (void *)coal_pl, (void *)coal_lc); all &= check("S1 private symbols resolvable", s1, d); if (!s1) return 1;
  // S2
  uint64_t my = coal_of_pid(getpid()); pid_t mem[4096]; size_t sz = sizeof mem; int inlist = 0, n = 0;
  if (my && coal_pl(my, mem, &sz) == 0) { n = sz / sizeof(pid_t); for (int i = 0; i < n; i++) if (mem[i] == getpid()) inlist = 1; }
  snprintf(d, sizeof d, "cid %llu, %d members", my, n); all &= check("S2 own coalition found and contains own pid", my && inlist, d);
  // S3
  unsigned char buf[512]; int w[2]; unsigned char pat[2] = {0xA5, 0x5A};
  for (int k = 0; k < 2; k++) { memset(buf, pat[k], sizeof buf); coal_cru(my, buf, sizeof buf); int last = -1; for (int i = 0; i < 512; i++) if (buf[i] != pat[k]) last = i; w[k] = last + 1; }
  int written = w[0] > w[1] ? w[0] : w[1]; uint64_t s[COAL_SLOTS]; coal_cru(my, s, sizeof s);
  snprintf(d, sizeof d, "writes %d bytes, slot23=%llu", written, s[23]); all &= check("S3 layout: 400 bytes / 50 slots, eqos_len == 7", written == 400 && s[23] == 7, d);
  // S4
  struct coal_listent *li; int nc = coal_list(&li); int used = 0, fp = 0, pg = 0, en = 0, pt = 0, ptn = 0, cpu2 = 0;
  for (int i = 0; i < nc && used < 400; i++) { if (li[i].tasks != 1) continue; pid_t p[4]; size_t z = sizeof p; if (coal_pl(li[i].cid, p, &z) || z != sizeof(pid_t)) continue;
    struct rusage_info_v6 r; if (!rusage6(p[0], &r)) continue; uint64_t q[COAL_SLOTS]; if (coal_cru(li[i].cid, q, sizeof q)) continue; if (q[0] - q[1] != 1) continue; used++;
    fp += q[40] == r.ri_phys_footprint; pg += q[49] == r.ri_pageins; en += q[11] == r.ri_energy_nj;
    uint64_t rp = r.ri_user_ptime + r.ri_system_ptime; if (rp || q[22]) { ptn++; pt += q[22] == rp; }
    uint64_t rt = r.ri_user_time + r.ri_system_time; if (rt && fabs((double)coal_cpu_ticks(q) / rt - 1) <= 0.02) cpu2++; }
  free(li);
  double f40 = used ? (double)fp / used : 0, f49 = used ? (double)pg / used : 0, f11 = used ? (double)en / used : 0, f22 = ptn ? (double)pt / ptn : 1, fc = used ? (double)cpu2 / used : 0;
  snprintf(d, sizeof d, "n=%d: slot40 %.0f%%, slot49 %.0f%%, slot11 %.0f%%, slot22 %.0f%% (n=%d), eqos±2%% %.0f%%", used, 100 * f40, 100 * f49, 100 * f11, 100 * f22, ptn, 100 * fc);
  all &= check("S4 level semantics on same-uid single-member coalitions", used >= 20 && f40 >= 0.9 && f49 >= 0.9 && f11 >= 0.8 && f22 >= 0.8 && fc >= 0.75, d);
  // S5
  struct rusage_info_v6 ra, rb; uint64_t sa[COAL_SLOTS], sb[COAL_SLOTS]; rusage6(getpid(), &ra); coal_cru(my, sa, sizeof sa);
  uint64_t t = now_ns(); volatile double x = 1; while (now_ns() - t < 60000000) x = x * 1.0000001 + 0.5;
  rusage6(getpid(), &rb); coal_cru(my, sb, sizeof sb);
  double dself = (double)((rb.ri_user_time + rb.ri_system_time) - (ra.ri_user_time + ra.ri_system_time)), dco = (double)(coal_cpu_ticks(sb) - coal_cpu_ticks(sa));
  double eself = (double)(rb.ri_energy_nj - ra.ri_energy_nj), eco = (double)(sb[11] - sa[11]);
  snprintf(d, sizeof d, "d(cpu) coal/self = %.4f, d(energy) coal/self = %.4f (members %d)", dself ? dco / dself : 0, eself ? eco / eself : 0, n);
  int s5 = dself > 0 && dco >= 0.95 * dself && eco >= 0.95 * eself && (n > 1 || fabs(dco / dself - 1) < 0.01);
  all &= check("S5 own-thread 60 ms spin shows up in own coalition", s5, d);
  double cpu_ms = (thread_cpu_ns() - c0) / 1e6 - (now_ns() - t > 0 ? 60 : 0), wall_ms = (now_ns() - w0) / 1e6;
  printf("RESULT %s; self-test cost excluding the 60 ms spin: ~%.2f ms thread CPU, %.1f ms wall\n", all ? "PASS -> use coalition source" : "FAIL -> fall back to same-uid libproc only, mark other processes unavailable", cpu_ms, wall_ms - 60);
  return all ? 0 : 1;
}
