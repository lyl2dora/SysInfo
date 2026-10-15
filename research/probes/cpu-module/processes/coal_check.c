// coal_check.c - resource coalition 在本机是否可用、槽位含义是否与 M5 实测一致、可见范围。只读。
//   A 符号解析；B 本进程 coalition；C coalition_info_resource_usage 真实写出字节数；D coalition_info_pid_list 缓冲不足时的行为；
//   E proc_listcoalitions 条目格式；F slot 23 (eqos_len)；G 同 uid 单成员 coalition 的槽位 ↔ rusage_info_v6 字段逐一对照；
//   H 全体（含 root/其他 uid）单成员 coalition 的生命周期累计值 ↔ top 的 TIME / IDLEW / MEM；
//   I 可见范围：各 libproc 调用按 uid 类别的成功率，coalition 对全体是否可读。
// build: xcrun clang -O1 -o coal_check coal_check.c
#include "coal.h"
#include <math.h>
#include <pwd.h>
#include <stddef.h>

typedef struct { const char *name; int slot; int slot2; size_t off; size_t off2; } Pair;  // slot2<0: 单槽；slot==-2: eqos 求和
#define OFF(f) offsetof(struct rusage_info_v6, f)
#define NONE ((size_t)-1)
static uint64_t slotval(const uint64_t *s, const Pair *p) { if (p->slot == -2) return coal_cpu_ticks(s); return s[p->slot] + (p->slot2 >= 0 ? s[p->slot2] : 0); }
static uint64_t fieldval(const struct rusage_info_v6 *r, const Pair *p) { uint64_t v = *(const uint64_t *)((const char *)r + p->off); if (p->off2 != NONE) v += *(const uint64_t *)((const char *)r + p->off2); return v; }

static int toppid[16384]; static double toptime[16384]; static long topidle[16384]; static double topmem[16384]; static int ntop;
static double parse_mem(const char *s) { double v = atof(s); size_t n = strlen(s); char u = n ? s[n - 1] : 0; if (u == '+' || u == '-') u = n > 1 ? s[n - 2] : 0;
  if (u == 'K') v *= 1024; else if (u == 'M') v *= 1048576; else if (u == 'G') v *= 1073741824.0; else if (u == 'B') v *= 1; return v; }
static int top_find(int pid) { for (int i = 0; i < ntop; i++) if (toppid[i] == pid) return i; return -1; }

int main(void) {
  print_machine();
  // ---------- A
  int ok = coal_init();
  printf("A) dlsym: coalition_info_resource_usage=%s coalition_info_pid_list=%s proc_listcoalitions=%s responsibility_get_pid_responsible_for_pid=%s -> %s\n",
         coal_cru ? "ok" : "MISSING", coal_pl ? "ok" : "MISSING", coal_lc ? "ok" : "MISSING", coal_resp ? "ok" : "MISSING", ok ? "usable" : "NOT usable");
  if (!ok) return 1;
  // ---------- B
  uint64_t mycid = coal_of_pid(getpid());
  { pid_t p[512]; size_t sz = sizeof p; int rc = coal_pl(mycid, p, &sz); int n = rc == 0 ? (int)(sz / sizeof(pid_t)) : -1; uint64_t s[COAL_SLOTS] = {0}; coal_cru(mycid, s, sizeof s);
    printf("B) own pid %d ppid %d resource coalition %llu: members=%d tasks_started=%llu exited=%llu; members:", getpid(), getppid(), mycid, n, s[0], s[1]);
    for (int i = 0; i < n && i < 40; i++) { struct proc_bsdshortinfo si; printf(" %d(%s)", p[i], shortinfo(p[i], &si) ? si.pbsi_comm : "?"); } printf("\n"); }
  // ---------- C
  { unsigned char buf[1024]; int written[2]; unsigned char pat[2] = {0xA5, 0x5A};
    for (int k = 0; k < 2; k++) { memset(buf, pat[k], sizeof buf); int rc = coal_cru(mycid, buf, 512); int last = -1; for (int i = 0; i < 512; i++) if (buf[i] != pat[k]) last = i; written[k] = last + 1; (void)rc; }
    int w = written[0] > written[1] ? written[0] : written[1];
    int rc360 = coal_cru(mycid, buf, 360), e360 = errno;
    printf("C) coalition_info_resource_usage writes %d bytes (= %d u64 slots) when given 512; given 360 (xnu-12377 size): rc=%d errno=%d; M5 reference: 400 bytes / 50 slots -> %s\n",
           w, w / 8, rc360, rc360 ? e360 : 0, w == 400 ? "SAME" : "DIFFERENT");
  }
  struct coal_listent *ci; int nc = coal_list(&ci);
  // ---------- D
  { int best = 0; for (int i = 0; i < nc; i++) if (ci[i].tasks > ci[best].tasks) best = i;
    pid_t p[4096]; size_t sz = 2 * sizeof(pid_t); memset(p, 0xff, sizeof p); errno = 0; int rc = coal_pl(ci[best].cid, p, &sz); int e = errno;
    int overwritten = 0; for (int i = 0; i < 4096; i++) if (p[i] != -1) overwritten = i + 1;
    size_t sz2 = sizeof p; int rc2 = coal_pl(ci[best].cid, p, &sz2);
    size_t sz0 = 0; errno = 0; int rc0 = coal_pl(ci[best].cid, NULL, &sz0); int e0 = errno;
    printf("D) pid_list on largest coalition cid %llu (tasks=%u): buffer for 2 pids -> rc=%d errno=%d size-after=%zu bytes, pids written=%d; full buffer -> rc=%d size-after=%zu (%zu pids); NULL/0 size query -> rc=%d errno=%d size-after=%zu\n",
           ci[best].cid, ci[best].tasks, rc, rc ? e : 0, sz, overwritten, rc2, sz2, sz2 / sizeof(pid_t), rc0, rc0 ? e0 : 0, sz0);
  }
  // ---------- E / F
  { int typebad = 0, agree = 0, empty = 0, empty_ok = 0, eq7 = 0, readable = 0; for (int i = 0; i < nc; i++) { if (ci[i].type != 0) typebad++;
      pid_t p[4096]; size_t sz = sizeof p; coal_pl(ci[i].cid, p, &sz); if ((int)(sz / sizeof(pid_t)) == (int)ci[i].tasks) agree++;
      uint64_t s[COAL_SLOTS]; int rc = coal_cru(ci[i].cid, s, sizeof s); if (rc == 0) { readable++; if (s[23] == 7) eq7++; } if (ci[i].tasks == 0) { empty++; if (rc == 0) empty_ok++; } }
    printf("E) proc_listcoalitions(2,0): %d resource coalitions (16 B/entry); type==0 for all: %s; tasks field == pid_list count: %d/%d; empty (0 live tasks): %d (still readable %d)\n", nc, typebad ? "NO" : "yes", agree, nc, empty, empty_ok);
    printf("F) cru readable for %d/%d coalitions; slot 23 (cpu_time_eqos_len) == 7 in %d/%d\n", readable, nc, eq7, readable);
  }
  // ---------- G
  Pair P[] = {
    {"11 energy_nj           == ri_energy_nj", 11, -1, OFF(ri_energy_nj), NONE},
    {"24..30 eqos sum        == ri_user+system_time", -2, -1, OFF(ri_user_time), OFF(ri_system_time)},
    {"3 cpu_time (ledger)    == ri_user+system_time", 3, -1, OFF(ri_user_time), OFF(ri_system_time)},
    {"22 cpu_ptime           == ri_user+system_ptime", 22, -1, OFF(ri_user_ptime), OFF(ri_system_ptime)},
    {"31 instructions        == ri_instructions", 31, -1, OFF(ri_instructions), NONE},
    {"32 cycles              == ri_cycles", 32, -1, OFF(ri_cycles), NONE},
    {"35 pinstructions       == ri_pinstructions", 35, -1, OFF(ri_pinstructions), NONE},
    {"36 pcycles             == ri_pcycles", 36, -1, OFF(ri_pcycles), NONE},
    {"40 phys_footprint      == ri_phys_footprint", 40, -1, OFF(ri_phys_footprint), NONE},
    {"4 interrupt_wakeups    == ri_interrupt_wkups", 4, -1, OFF(ri_interrupt_wkups), NONE},
    {"5 platform_idle_wkups  == ri_pkg_idle_wkups", 5, -1, OFF(ri_pkg_idle_wkups), NONE},
    {"6 bytesread            == ri_diskio_bytesread", 6, -1, OFF(ri_diskio_bytesread), NONE},
    {"7 byteswritten         == ri_diskio_byteswritten", 7, -1, OFF(ri_diskio_byteswritten), NONE},
    {"9 cpu_billed_to_me     == ri_billed_system_time", 9, -1, OFF(ri_billed_system_time), NONE},
    {"10 cpu_billed_to_others== ri_serviced_system_time", 10, -1, OFF(ri_serviced_system_time), NONE},
    {"20 energy_billed_to_me == ri_billed_energy", 20, -1, OFF(ri_billed_energy), NONE},
    {"21 energy_billed_others== ri_serviced_energy", 21, -1, OFF(ri_serviced_energy), NONE},
    {"49 pageins             == ri_pageins", 49, -1, OFF(ri_pageins), NONE},
  };
  static char bad[8][160]; int nbad = 0;
  int NP = sizeof P / sizeof P[0]; int both[32] = {0}, hit2[32] = {0}, exact[32] = {0}, zero_s[32] = {0}, used = 0; uid_t me = getuid();
  for (int i = 0; i < nc; i++) { pid_t p[8]; size_t sz = sizeof p; if (coal_pl(ci[i].cid, p, &sz) || sz != sizeof(pid_t)) continue;
    struct rusage_info_v6 r; if (!rusage6(p[0], &r)) continue; uint64_t s[COAL_SLOTS]; if (coal_cru(ci[i].cid, s, sizeof s)) continue;
    if (s[0] - s[1] != 1) continue; used++;
    { uint64_t a = coal_cpu_ticks(s), b = r.ri_user_time + r.ri_system_time; double q = b ? (double)a / b : 0; if (b && fabs(q - 1) > 0.02 && nbad < 8) {
        struct proc_bsdshortinfo si; shortinfo(p[0], &si); snprintf(bad[nbad++], 160, "pid %d %-16s tasks_started=%llu eqos=%.3fs rusage=%.3fs ratio=%.3f slot3=%.3fs diff=%.3fs", p[0], si.pbsi_comm, s[0], a * tick_to_ns() / 1e9, b * tick_to_ns() / 1e9, q, s[3] * tick_to_ns() / 1e9, ((double)a - b) * tick_to_ns() / 1e9); } }
    for (int k = 0; k < NP; k++) { uint64_t a = slotval(s, &P[k]), b = fieldval(&r, &P[k]); if (!a && !b) { zero_s[k]++; continue; } both[k]++; if (a == b) exact[k]++;
      if (b && fabs((double)a / b - 1) <= 0.02) hit2[k]++; } }
  printf("G) same-uid (uid %d) single-member coalitions used: %d. slot vs rusage_info_v6 (both-zero pairs excluded):\n", me, used);
  for (int k = 0; k < nbad; k++) printf("   eqos-sum mismatch sample: %s\n", bad[k]);
  for (int k = 0; k < NP; k++) printf("   %-50s within 2%%: %3d/%3d  exact: %3d/%3d  (both zero: %d)\n", P[k].name, hit2[k], both[k], exact[k], both[k], zero_s[k]);
  // ---------- H
  { FILE *f = popen("/usr/bin/top -l 1 -o pid -n 10000 -stats pid,time,idlew,mem 2>/dev/null", "r"); char line[512]; int intable = 0; ntop = 0;
    while (f && fgets(line, sizeof line, f)) { if (!strncmp(line, "PID", 3)) { intable = 1; continue; } if (!intable) continue;
      int pid; char tm[64], mem[64]; long iw; if (sscanf(line, "%d %63s %ld %63s", &pid, tm, &iw, mem) != 4) continue;
      int a = 0, b = 0, c = 0, hs = 0; double secs; if (!strchr(tm, '.') && sscanf(tm, "%d:%d:%d", &a, &b, &c) == 3) secs = a * 3600 + b * 60 + c; else if (sscanf(tm, "%d:%d.%d", &a, &b, &hs) == 3) secs = a * 60 + b + hs / 100.0; else continue;
      toppid[ntop] = pid; toptime[ntop] = secs; topidle[ntop] = iw; topmem[ntop] = parse_mem(mem); ntop++; }
    if (f) pclose(f);
    int n = 0, nf = 0, t_ok = 0, t_okf = 0, i_ok = 0, i_okf = 0, m_ok = 0, m_okf = 0, s3_ok = 0;
    for (int i = 0; i < nc; i++) { pid_t p[8]; size_t sz = sizeof p; if (coal_pl(ci[i].cid, p, &sz) || sz != sizeof(pid_t)) continue; int t = top_find(p[0]); if (t < 0) continue;
      uint64_t s[COAL_SLOTS]; if (coal_cru(ci[i].cid, s, sizeof s)) continue; struct proc_bsdshortinfo si; int foreign = shortinfo(p[0], &si) && si.pbsi_uid != me; n++; nf += foreign;
      double eq = coal_cpu_ticks(s) * tick_to_ns() / 1e9, s3 = s[3] * tick_to_ns() / 1e9, tol = toptime[t] >= 3600 ? 1.5 : fmax(0.02, toptime[t] * 0.005);
      if (fabs(eq - toptime[t]) <= tol) { t_ok++; t_okf += foreign; } if (fabs(s3 - toptime[t]) <= tol) s3_ok++;
      if (labs((long)s[5] - topidle[t]) <= 2 || fabs((double)s[5] / (topidle[t] ? topidle[t] : 1) - 1) < 0.001) { i_ok++; i_okf += foreign; }
      // top MEM 显示 3 位有效数字左右 → 允许 1% 或 1 个显示单位
      double mb = s[40]; if (fabs(mb - topmem[t]) <= fmax(topmem[t] * 0.01, 1024 * 1024)) { m_ok++; m_okf += foreign; } }
    printf("H) single-member coalitions (all uids) matched to one `top -l 1` snapshot: %d (foreign uid %d)\n", n, nf);
    printf("   sum(eqos 24..30) == top TIME : %d/%d (foreign %d/%d)   [slot 3 == TIME: %d/%d]\n", t_ok, n, t_okf, nf, s3_ok, n);
    printf("   slot 5 == top IDLEW          : %d/%d (foreign %d/%d)\n", i_ok, n, i_okf, nf);
    printf("   slot 40 == top MEM (1%%/1MiB) : %d/%d (foreign %d/%d)\n", m_ok, n, m_okf, nf);
  }
  // ---------- I
  { static pid_t pids[16384]; int np = proc_listallpids(pids, sizeof pids); const char *cat[3] = {"own uid", "root", "other uid"};
    int tot[3] = {0}, ru[3] = {0}, ti[3] = {0}, sb[3] = {0}, pp[3] = {0}, pn[3] = {0}, kp[3] = {0}, rp[3] = {0}, bsd[3] = {0}, co[3] = {0};
    for (int i = 0; i < np; i++) { struct proc_bsdshortinfo si; int okb = shortinfo(pids[i], &si); int c;
      struct kinfo_proc k; size_t ksz = sizeof k; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pids[i]}; int okk = sysctl(mib, 4, &k, &ksz, NULL, 0) == 0 && ksz > 0;
      uid_t u = okb ? si.pbsi_uid : (okk ? k.kp_eproc.e_ucred.cr_uid : 99999); c = u == me ? 0 : (u == 0 ? 1 : 2); tot[c]++; sb[c] += okb; kp[c] += okk;
      struct rusage_info_v6 r; ru[c] += rusage6(pids[i], &r); struct proc_taskinfo t; ti[c] += proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &t, sizeof t) == sizeof t;
      char path[PROC_PIDPATHINFO_MAXSIZE]; pp[c] += proc_pidpath(pids[i], path, sizeof path) > 0; char nm[256]; pn[c] += proc_name(pids[i], nm, sizeof nm) > 0;
      struct proc_bsdinfo bi; bsd[c] += proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == sizeof bi;
      if (coal_resp) rp[c] += coal_resp(pids[i]) > 0; co[c] += coal_of_pid(pids[i]) != 0; }
    printf("I) visibility over %d pids (uid %d):\n   %-10s %6s %10s %10s %10s %10s %10s %10s %10s %12s %10s\n", np, me, "class", "n", "rusage_v6", "TASKINFO", "TBSDINFO", "SHORTBSD", "pidpath", "proc_name", "kinfo", "responsible", "PIDCOAL");
    for (int c = 0; c < 3; c++) printf("   %-10s %6d %10d %10d %10d %10d %10d %10d %10d %12d %10d\n", cat[c], tot[c], ru[c], ti[c], bsd[c], sb[c], pp[c], pn[c], kp[c], rp[c], co[c]);
    // 所有 coalition 都可读？按「成员全是 root / 含其他 uid / 含本 uid」分类
    int croot = 0, crootok = 0, cother = 0, cotherok = 0, cown = 0, cownok = 0;
    for (int i = 0; i < nc; i++) { pid_t p[4096]; size_t sz = sizeof p; if (coal_pl(ci[i].cid, p, &sz)) continue; int n = sz / sizeof(pid_t); if (!n) continue; int hasown = 0, allroot = 1;
      for (int k = 0; k < n; k++) { struct proc_bsdshortinfo si; if (!shortinfo(p[k], &si)) continue; if (si.pbsi_uid == me) hasown = 1; if (si.pbsi_uid != 0) allroot = 0; }
      uint64_t s[COAL_SLOTS]; int rok = coal_cru(ci[i].cid, s, sizeof s) == 0;
      if (hasown) { cown++; cownok += rok; } else if (allroot) { croot++; crootok += rok; } else { cother++; cotherok += rok; } }
    printf("   coalitions with live members: containing own-uid member %d (readable %d); all-root %d (readable %d); other (foreign non-root) %d (readable %d)\n", cown, cownok, croot, crootok, cother, cotherok);
  }
  free(ci); return 0;
}
