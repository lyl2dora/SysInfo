// Review probe: how many root-owned pids sit alone in their resource coalition (=> coalition I/O == per-process I/O)?
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <sys/proc_info.h>
#define PROC_PIDCOALITIONINFO 20
struct proc_pidcoalitioninfo { uint64_t coalition_id[2]; uint64_t r1, r2, r3; };
int main(void) {
    int n = proc_listallpids(NULL, 0); pid_t *p = calloc(n + 64, sizeof(pid_t)); n = proc_listallpids(p, (n + 64) * sizeof(pid_t));
    uint64_t *cid = calloc(n, 8); uid_t *uid = calloc(n, sizeof(uid_t)); char (*nm)[17] = calloc(n, 17);
    for (int i = 0; i < n; i++) { struct proc_pidcoalitioninfo c = {0}; proc_pidinfo(p[i], PROC_PIDCOALITIONINFO, 0, &c, sizeof c); cid[i] = c.coalition_id[0];
        struct proc_bsdshortinfo b = {0}; proc_pidinfo(p[i], PROC_PIDT_SHORTBSDINFO, 0, &b, sizeof b); uid[i] = b.pbsi_uid; strncpy(nm[i], b.pbsi_comm, 16); }
    int root = 0, alone = 0, other_uid = 0, other_alone = 0;
    for (int i = 0; i < n; i++) {
        int cnt = 0; for (int j = 0; j < n; j++) cnt += cid[j] == cid[i];
        if (uid[i] == 0) { root++; if (cnt == 1) alone++; else if (root - alone <= 8) printf("  shared: pid %d %s coalition %llu has %d pids\n", p[i], nm[i], cid[i], cnt); }
        else if (uid[i] != 501) { other_uid++; if (cnt == 1) other_alone++; }
    }
    printf("root pids=%d alone-in-coalition=%d; other non-501 pids=%d alone=%d\n", root, alone, other_uid, other_alone);
    return 0;
}
