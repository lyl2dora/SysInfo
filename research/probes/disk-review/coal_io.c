// Review probe: can an unprivileged user get disk I/O for ROOT processes via resource coalitions?
// proc_pidinfo(PROC_PIDCOALITIONINFO=20, private) -> resource coalition id; coalition_info_resource_usage (private
// libsystem_kernel export) -> bytesread/byteswritten (struct layout from XNU sys/coalition.h: offsets 48/56).
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
#define PROC_PIDCOALITIONINFO 20
struct proc_pidcoalitioninfo { uint64_t coalition_id[2]; uint64_t reserved1, reserved2, reserved3; };
extern int coalition_info_resource_usage(uint64_t cid, void *cru, size_t sz);
typedef struct { uint64_t cid; uint64_t r, w; char name[64]; uid_t uid; int npids; } coal_t;
static coal_t C[4096]; static int NC;
static coal_t *find(uint64_t cid) { for (int i = 0; i < NC; i++) if (C[i].cid == cid) return &C[i]; C[NC].cid = cid; return &C[NC++]; }
static int sample(int print_errs) {
    int n = proc_listallpids(NULL, 0); pid_t *p = calloc(n + 64, sizeof(pid_t));
    n = proc_listallpids(p, (n + 64) * sizeof(pid_t));
    int ok = 0, fail = 0, rootok = 0, cinfo_fail = 0;
    for (int i = 0; i < n; i++) {
        struct proc_pidcoalitioninfo ci; memset(&ci, 0, sizeof ci);
        if (proc_pidinfo(p[i], PROC_PIDCOALITIONINFO, 0, &ci, sizeof ci) <= 0) { cinfo_fail++; continue; }
        struct proc_bsdshortinfo bi; memset(&bi, 0, sizeof bi);
        proc_pidinfo(p[i], PROC_PIDT_SHORTBSDINFO, 0, &bi, sizeof bi);
        coal_t *c = find(ci.coalition_id[0]);
        c->npids++;
        if (c->npids == 1) { strncpy(c->name, bi.pbsi_comm, 63); c->uid = bi.pbsi_uid; }
        if (bi.pbsi_uid == 0 && c->uid != 0) { c->uid = 0; strncpy(c->name, bi.pbsi_comm, 63); }
    }
    for (int i = 0; i < NC; i++) {
        uint64_t buf[256]; memset(buf, 0, sizeof buf);
        int r = coalition_info_resource_usage(C[i].cid, buf, sizeof buf);
        if (r == 0) { C[i].r = buf[6]; C[i].w = buf[7]; ok++; if (C[i].uid == 0) rootok++; }
        else { fail++; if (print_errs && fail < 5) printf("  coalition %llu (%s) err=%d errno=%d\n", C[i].cid, C[i].name, r, errno); }
    }
    printf("pids=%d coalitions=%d usage ok=%d (with root member: %d) fail=%d, PROC_PIDCOALITIONINFO failures=%d\n", n, NC, ok, rootok, fail, cinfo_fail);
    free(p); return ok;
}
int main(void) {
    printf("uid=%d\n", getuid());
    sample(1);
    coal_t before[4096]; int nb = NC; memcpy(before, C, sizeof(coal_t) * NC);
    printf("sample of root-led coalitions (lifetime bytes):\n");
    int shown = 0;
    for (int i = 0; i < NC && shown < 8; i++) if (C[i].uid == 0 && C[i].w > 0) { printf("  cid=%llu %-24s pids=%d read=%llu written=%llu\n", C[i].cid, C[i].name, C[i].npids, C[i].r, C[i].w); shown++; }
    sleep(5);
    for (int i = 0; i < NC; i++) C[i].npids = 0;
    sample(0);
    printf("top coalitions by disk I/O over 5 s:\n");
    typedef struct { int i; uint64_t d; } D; D d[4096]; int nd = 0;
    for (int i = 0; i < nb; i++) { uint64_t dr = C[i].r - before[i].r, dw = C[i].w - before[i].w; if (dr + dw > 0) { d[nd].i = i; d[nd].d = dr + dw; nd++; } }
    for (int a = 0; a < nd; a++) for (int b = a + 1; b < nd; b++) if (d[b].d > d[a].d) { D t = d[a]; d[a] = d[b]; d[b] = t; }
    for (int k = 0; k < nd && k < 12; k++) { int i = d[k].i; printf("  cid=%llu %-24s uid=%d read=+%llu written=+%llu\n", C[i].cid, C[i].name, C[i].uid, C[i].r - before[i].r, C[i].w - before[i].w); }
    printf("coalitions with nonzero I/O in window: %d\n", nd);
    return 0;
}
