// sk_misc.c - 几项小结论的独立复核：
//  1) resource_usage 实际写出字节数与 slot 23（对方自检 S3 要求恰好 400 字节）；
//  2) coalition_info_pid_list 缓冲不足时的行为（对方：rc=0、静默截断、NULL 不回报所需大小）；
//  3) sysctl KERN_PROC_ALL 一次取全部的开销与条数（对方：0.06–0.07 ms），以及逐 pid KERN_PROC_PID 的开销（对方：5.6–13 µs/pid）；
//  4) PROC_PIDUNIQIDENTIFIERINFO(17) 对外部进程是否可用（可替代 KERN_PROC_PID 作名称缓存键）及其开销。
// 不制造负载。build: xcrun clang -O1 -o sk_misc sk_misc.c
#include "sk.h"
struct sk_uniq { uint8_t uuid[16]; uint64_t uniqueid, puniqueid; int32_t idversion; uint32_t r2; uint64_t r3, r4; };
int main(void) {
  sk_machine(); if (!sk_init()) return 1; struct sk_ent *li; int n = sk_list(&li);
  int hist[4096 / 8 + 1] = {0}, s23 = 0, rd = 0; uint64_t big = 0; uint32_t bigt = 0;
  for (int i = 0; i < n; i++) { int w = sk_probe_size(li[i].cid); if (w < 0) continue; rd++; hist[(w + 7) / 8]++; uint64_t s[SKS]; sk_cru(li[i].cid, s, sizeof s); s23 += s[23] == 7; if (li[i].tasks > bigt) { bigt = li[i].tasks; big = li[i].cid; } }
  printf("1) resource_usage bytes written (given 512):"); for (int i = 0; i <= 64; i++) if (hist[i]) printf(" %d B x%d", i * 8, hist[i]); printf("; slot23==7 in %d/%d readable\n", s23, rd);
  pid_t buf[8] = {0}; size_t sz = 2 * sizeof(pid_t); int rc = sk_pl(big, buf, &sz); int e = errno;
  size_t sz0 = 0; int rc0 = sk_pl(big, NULL, &sz0);
  printf("2) pid_list on cid %llu (tasks %u): buffer for 2 -> rc %d errno %d size-after %zu; NULL/0 -> rc %d size-after %zu\n", big, bigt, rc, rc ? e : 0, sz, rc0, sz0);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}; double v[40]; size_t got = 0; int nerr = 0;
  for (int r = 0; r < 40; r++) { uint64_t c0 = sk_tcpu(); size_t z = 0; sysctl(mib, 3, NULL, &z, NULL, 0); z += 32 * sizeof(struct kinfo_proc); void *b = malloc(z); if (sysctl(mib, 3, b, &z, NULL, 0)) nerr++; got = z; free(b); v[r] = (sk_tcpu() - c0) / 1e3; }
  printf("3) KERN_PROC_ALL: median %.1f us (thread CPU), returned %zu entries (sizeof kinfo_proc %zu), errors %d/40\n", sk_med(v, 40), got / sizeof(struct kinfo_proc), sizeof(struct kinfo_proc), nerr);
  pid_t pids[16384]; int np = proc_listallpids(pids, sizeof pids); double vp[5], vu[5]; int uok = 0;
  for (int r = 0; r < 5; r++) { uint64_t c0 = sk_tcpu(); for (int i = 0; i < np; i++) { struct kinfo_proc k; size_t z = sizeof k; int m[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pids[i]}; sysctl(m, 4, &k, &z, NULL, 0); } vp[r] = (sk_tcpu() - c0) / 1e3 / np;
    c0 = sk_tcpu(); uok = 0; for (int i = 0; i < np; i++) { struct sk_uniq u; uok += proc_pidinfo(pids[i], 17, 0, &u, sizeof u) == sizeof u; } vu[r] = (sk_tcpu() - c0) / 1e3 / np; }
  printf("   KERN_PROC_PID per pid: median %.2f us over %d pids;  4) PROC_PIDUNIQIDENTIFIERINFO per pid: median %.2f us, ok %d/%d\n", sk_med(vp, 5), np, sk_med(vu, 5), uok, np);
  return 0; }
