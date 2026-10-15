// sk_vs_ps.c - 复核「coalition 槽 24–30 之和 = 全体进程（含 root/其他 uid）的 CPU 时间」，重点是对方没有覆盖的多成员 coalition 与 kernel_task。
// 参照：setuid 的 /bin/ps -axo pid=,time=（10 ms 分辨率，覆盖除 pid 0 外全部进程）；kernel_task 用 top -l 2 -s W -pid 0 的 %CPU。
// 窗口 W 秒（默认 20）。只比较窗口两端成员列表相同、tasks_started/exited 都没变的 coalition。
// 不制造负载（机器上其他 agent 的负载即被测对象）。用法：sk_vs_ps [W=20]
// build: xcrun clang -O1 -o sk_vs_ps sk_vs_ps.c
#include "sk.h"
#include <math.h>
#define MAXC 4096
#define MAXP 8192
typedef struct { uint64_t cid; uint64_t s[SKS]; int nm; pid_t m[64]; int ok; } Snap;
static Snap A[MAXC], B[MAXC]; static int nA, nB;
static double psA[100000], psB[100000];   // pid -> 秒；-1 = 不存在
static void ps_snap(double *t) {
  for (int i = 0; i < 100000; i++) t[i] = -1;
  FILE *f = popen("/bin/ps -axo pid=,time=", "r"); char line[256];
  while (fgets(line, sizeof line, f)) { int pid; char tm[64]; if (sscanf(line, "%d %63s", &pid, tm) != 2 || pid < 0 || pid >= 100000) continue;
    double h = 0, m = 0, s = 0; int c = 0; for (char *p = tm; *p; p++) c += *p == ':';
    if (c == 2) sscanf(tm, "%lf:%lf:%lf", &h, &m, &s); else if (c == 1) sscanf(tm, "%lf:%lf", &m, &s); else continue;
    t[pid] = h * 3600 + m * 60 + s; }
  pclose(f); }
static int coal_snap(Snap *S) { struct sk_ent *li; int n = sk_list(&li), k = 0;
  for (int i = 0; i < n && k < MAXC; i++) { if (!li[i].tasks) continue; Snap *x = &S[k]; x->cid = li[i].cid; x->ok = sk_cru(x->cid, x->s, sizeof x->s) == 0;
    x->nm = sk_members(x->cid, x->m, 64); if (x->nm < 0 || x->nm > 64) x->ok = 0; k++; }
  free(li); return k; }
static int cmpd(const void *a, const void *b) { double x = fabs(*(const double *)a), y = fabs(*(const double *)b); return (x > y) - (x < y); }
int main(int argc, char **argv) {
  int W = argc > 1 ? atoi(argv[1]) : 20; sk_machine(); if (!sk_init()) return 1; double k = sk_tb() / 1e9;
  char cmd[128]; snprintf(cmd, sizeof cmd, "/usr/bin/top -l 2 -s %d -pid 0 -stats pid,cpu,time", W);
  FILE *top = popen(cmd, "r"); char line[512]; int hdr = 0; double kt_cpu = -1; uint64_t tA = 0, tB = 0;
  // 等 top 打出第 1 个样本的表头，随即取快照 A；第 2 个样本表头出现时取快照 B
  while (fgets(line, sizeof line, top)) {
    if (!strncmp(line, "Processes:", 10)) { hdr++; if (hdr == 1) { ps_snap(psA); nA = coal_snap(A); tA = sk_now(); } else { ps_snap(psB); nB = coal_snap(B); tB = sk_now(); } }
    int pid; double c; char tm[64]; if (hdr == 2 && sscanf(line, "%d %lf %63s", &pid, &c, tm) == 3 && pid == 0) kt_cpu = c; }
  pclose(top); double dt = (tB - tA) / 1e9;
  printf("window %.2f s (top -s %d); coalitions A %d, B %d; kernel_task %%CPU from top = %.1f\n", dt, W, nA, nB, kt_cpu);
  int cmp = 0, multi = 0, skipped = 0; double err[MAXC], errm[MAXC], rat[MAXC]; int ne = 0, nem = 0, nr = 0; char nm[64];
  printf("   %-7s %-4s %9s %9s %8s  members\n", "cid", "n", "coal%", "ref%", "diff_pp");
  typedef struct { double c, r; int i, j; } Row; static Row rows[MAXC]; int nrow = 0;
  for (int i = 0; i < nA; i++) { Snap *a = &A[i], *b = NULL; for (int j = 0; j < nB; j++) if (B[j].cid == a->cid) { b = &B[j]; break; }
    if (!b || !a->ok || !b->ok || a->nm != b->nm || a->s[0] != b->s[0] || a->s[1] != b->s[1]) { skipped++; continue; }
    int same = 1; for (int m = 0; m < a->nm; m++) if (a->m[m] != b->m[m]) same = 0; if (!same) { skipped++; continue; }
    double ref = 0; int refok = 1; for (int m = 0; m < a->nm; m++) { pid_t p = a->m[m];
      if (p == 0) { if (kt_cpu < 0) refok = 0; else ref += kt_cpu / 100 * dt; continue; }
      if (psA[p] < 0 || psB[p] < 0) { refok = 0; break; } ref += psB[p] - psA[p]; }
    if (!refok) { skipped++; continue; }
    double c = (sk_eqos(b->s) - sk_eqos(a->s)) * k; double cp = 100 * c / dt, rp = 100 * ref / dt; cmp++;
    err[ne++] = cp - rp; if (a->nm > 1) { errm[nem++] = cp - rp; multi++; } if (rp >= 1) rat[nr++] = cp / rp;
    rows[nrow].c = cp; rows[nrow].r = rp; rows[nrow].i = i; nrow++; }
  // 按 coalition CPU 排序打印前 20
  for (int x = 0; x < nrow; x++) for (int y = x + 1; y < nrow; y++) if (rows[y].c > rows[x].c) { Row t = rows[x]; rows[x] = rows[y]; rows[y] = t; }
  for (int x = 0; x < nrow && x < 20; x++) { Snap *a = &A[rows[x].i]; printf("   %-7llu %-4d %9.2f %9.2f %+8.2f ", a->cid, a->nm, rows[x].c, rows[x].r, rows[x].c - rows[x].r);
    for (int m = 0; m < a->nm && m < 5; m++) printf(" %s", sk_name(a->m[m], nm, sizeof nm)); if (a->nm > 5) printf(" +%d", a->nm - 5); printf("\n"); }
  // kernel_task 所在 coalition
  for (int i = 0; i < nA; i++) for (int m = 0; m < A[i].nm; m++) if (A[i].m[m] == 0) { Snap *a = &A[i]; for (int j = 0; j < nB; j++) if (B[j].cid == a->cid) {
    double c = (sk_eqos(B[j].s) - sk_eqos(a->s)) * k, s3 = (B[j].s[3] - a->s[3]) * k; double l = (psB[1] >= 0 && psA[1] >= 0) ? psB[1] - psA[1] : -1;
    printf("kernel coalition cid %llu (%d members):", a->cid, a->nm); for (int q = 0; q < a->nm && q < 6; q++) printf(" %s", sk_name(a->m[q], nm, sizeof nm));
    printf("\n   coalition eqos %.2f%%, slot3 %.2f%%; reference: kernel_task(top) %.2f%% + launchd(ps) %.2f%% = %.2f%%\n", 100 * c / dt, 100 * s3 / dt, kt_cpu, 100 * l / dt, kt_cpu + 100 * l / dt); } }
  double *e2 = malloc(ne * sizeof *e2); memcpy(e2, err, ne * sizeof *e2); qsort(e2, ne, sizeof *e2, cmpd);
  double sa = 0; for (int i = 0; i < ne; i++) sa += fabs(err[i]); double sm = 0; for (int i = 0; i < nem; i++) sm += fabs(errm[i]);
  qsort(errm, nem, sizeof *errm, cmpd);
  printf("compared %d coalitions (multi-member %d), skipped %d (membership changed / unreadable / pid missing)\n", cmp, multi, skipped);
  printf("|coal - ref| pp: all mean %.4f p95 %.4f max %.3f; multi-member mean %.4f p95 %.4f max %.3f\n", ne ? sa / ne : 0, ne ? fabs(e2[(int)(0.95 * (ne - 1))]) : 0, ne ? fabs(e2[ne - 1]) : 0,
         nem ? sm / nem : 0, nem ? fabs(errm[(int)(0.95 * (nem - 1))]) : 0, nem ? fabs(errm[nem - 1]) : 0);
  qsort(rat, nr, sizeof *rat, sk_cmpd); if (nr) printf("coal/ref for coalitions with ref >= 1%%: n=%d, min %.3f, median %.3f, max %.3f\n", nr, rat[0], rat[nr / 2], rat[nr - 1]);
  return 0; }
