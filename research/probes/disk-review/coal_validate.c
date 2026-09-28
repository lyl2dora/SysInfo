// Validate coalition_resource_usage offsets: own coalition bytes written must grow by >= our 64 MiB write.
// Also show that a root daemon's coalition (launchd cid 1 / mds_stores) is readable while proc_pid_rusage on it fails.
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#define PROC_PIDCOALITIONINFO 20
struct proc_pidcoalitioninfo { uint64_t coalition_id[2]; uint64_t reserved1, reserved2, reserved3; };
extern int coalition_info_resource_usage(uint64_t cid, void *cru, size_t sz);
static int usage(uint64_t cid, uint64_t *b) { memset(b, 0, 2048); return coalition_info_resource_usage(cid, b, 2048); }
int main(void) {
    struct proc_pidcoalitioninfo ci; proc_pidinfo(getpid(), PROC_PIDCOALITIONINFO, 0, &ci, sizeof ci);
    uint64_t a[256], b[256];
    usage(ci.coalition_id[0], a);
    printf("own pid %d resource coalition %llu: tasks_started=%llu tasks_exited=%llu read=%llu written=%llu\n", getpid(), ci.coalition_id[0], a[0], a[1], a[6], a[7]);
    const char *f = "/tmp/sysinfo-probes/disk-review/coal.bin";
    size_t n = 64 << 20; char *buf = malloc(n); arc4random_buf(buf, n);
    int fd = open(f, O_CREAT | O_TRUNC | O_RDWR, 0644); fcntl(fd, F_NOCACHE, 1); write(fd, buf, n); fcntl(fd, F_FULLFSYNC); close(fd); unlink(f);
    usage(ci.coalition_id[0], b);
    printf("after 64 MiB (67108864 B) uncached write: coalition written +%llu read +%llu\n", b[7] - a[7], b[6] - a[6]);
    // root processes
    int np = proc_listallpids(NULL, 0); pid_t *p = calloc(np + 64, sizeof(pid_t)); np = proc_listallpids(p, (np + 64) * sizeof(pid_t));
    int shown = 0;
    for (int i = 0; i < np && shown < 6; i++) {
        struct proc_bsdshortinfo bi; if (proc_pidinfo(p[i], PROC_PIDT_SHORTBSDINFO, 0, &bi, sizeof bi) <= 0 || bi.pbsi_uid != 0) continue;
        if (strcmp(bi.pbsi_comm, "mds_stores") && strcmp(bi.pbsi_comm, "mds") && strcmp(bi.pbsi_comm, "backupd") && strcmp(bi.pbsi_comm, "logd") && strcmp(bi.pbsi_comm, "fseventsd") && strcmp(bi.pbsi_comm, "kernel_task")) continue;
        struct rusage_info_v6 ru; int rr = proc_pid_rusage(p[i], RUSAGE_INFO_V6, (rusage_info_t *)&ru); int e = errno;
        struct proc_pidcoalitioninfo c2; memset(&c2, 0, sizeof c2); proc_pidinfo(p[i], PROC_PIDCOALITIONINFO, 0, &c2, sizeof c2);
        uint64_t u[256]; int cr = usage(c2.coalition_id[0], u);
        char path[PROC_PIDPATHINFO_MAXSIZE] = ""; proc_pidpath(p[i], path, sizeof path);
        int pn = 0; // count pids in same coalition
        for (int j = 0; j < np; j++) { struct proc_pidcoalitioninfo c3; if (proc_pidinfo(p[j], PROC_PIDCOALITIONINFO, 0, &c3, sizeof c3) > 0 && c3.coalition_id[0] == c2.coalition_id[0]) pn++; }
        printf("pid %d %s (uid 0) path=%s: proc_pid_rusage=%d errno=%d | coalition %llu (%d pids) rc=%d read=%llu written=%llu\n", p[i], bi.pbsi_comm, path, rr, rr ? e : 0, c2.coalition_id[0], pn, cr, u[6], u[7]);
        shown++;
    }
    return 0;
}
