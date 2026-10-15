// coverage.c - 「按进程」视图能精确给出多少个外部（root / 其他 uid）进程：独占一个 coalition → 精确；
// 所在 coalition 只剩它一个不可读成员 → 残差精确（窗口内无成员进出时）；否则只能按组。只读。
// build: xcrun clang -O1 -o coverage coverage.c
#include "coal.h"
int main(void) { print_machine(); coal_init(); uid_t me = getuid(); struct coal_listent *li; int n = coal_list(&li);
  int foreign = 0, sole = 0, resid = 0, group = 0, own = 0, pidsum = 0;
  for (int i = 0; i < n; i++) { if (!li[i].tasks) continue; pid_t p[4096]; size_t sz = sizeof p; if (coal_pl(li[i].cid, p, &sz)) continue; int m = sz / sizeof(pid_t), unread = 0, fr = 0; pidsum += m;
    for (int k = 0; k < m; k++) { struct proc_bsdshortinfo si; struct rusage_info_v6 r; if (!shortinfo(p[k], &si)) { unread++; fr++; continue; } if (si.pbsi_uid != me) fr++; else own++; if (!rusage6(p[k], &r)) unread++; }
    foreign += fr; if (!fr) continue; if (m == 1) sole += fr; else if (unread == 1) resid += fr; else group += fr; }
  printf("pids in live coalitions %d (own uid %d, foreign %d): foreign sole member %d (%.0f%%), only unreadable member of its coalition %d (%.0f%%), group-only %d (%.0f%%)\n",
         pidsum, own, foreign, sole, 100.0 * sole / foreign, resid, 100.0 * resid / foreign, group, 100.0 * group / foreign); return 0; }
