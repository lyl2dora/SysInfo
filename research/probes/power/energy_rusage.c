// energy_rusage.c — native alternative to Stats' `top -o power` (Battery ProcessReader):
// proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj for all visible pids, two samples 2 s apart -> per-process watts.
#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#define MAXP 8192
typedef struct { pid_t pid; uint64_t nj, pnj, billed; int ok; } s_t;
static int cmp(const void *a, const void *b) { double x = ((double *)a)[1], y = ((double *)b)[1]; return x < y ? 1 : x > y ? -1 : 0; }

int main(void) {
    static pid_t pids[MAXP]; static s_t s0[MAXP];
    int n = proc_listallpids(pids, sizeof pids) ; if (n > MAXP) n = MAXP;
    int ok = 0, eperm = 0, other = 0;
    for (int i = 0; i < n; i++) {
        struct rusage_info_v6 ri; s0[i].pid = pids[i];
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ri) == 0) {
            s0[i].nj = ri.ri_energy_nj; s0[i].pnj = ri.ri_penergy_nj; s0[i].billed = ri.ri_billed_energy; s0[i].ok = 1; ok++;
        } else { s0[i].ok = 0; if (errno == EPERM) eperm++; else other++; }
    }
    printf("pids=%d rusage ok=%d EPERM=%d other_err=%d (uid=%d)\n", n, ok, eperm, other, getuid());
    sleep(2);
    static double rows[MAXP][2]; int m = 0;
    for (int i = 0; i < n; i++) {
        if (!s0[i].ok) continue;
        struct rusage_info_v6 ri;
        if (proc_pid_rusage(s0[i].pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) continue;
        double w = (double)(ri.ri_energy_nj - s0[i].nj) / 2e9;
        rows[m][0] = s0[i].pid; rows[m][1] = w; m++;
    }
    qsort(rows, m, sizeof rows[0], cmp);
    printf("top 10 by ri_energy_nj delta (W over 2 s):\n");
    for (int i = 0; i < m && i < 10; i++) {
        char name[256] = ""; proc_name((pid_t)rows[i][0], name, sizeof name);
        printf("  pid=%-6d %-28s %.3f W\n", (int)rows[i][0], name, rows[i][1]);
    }
    return 0;
}
