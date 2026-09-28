// Review probe: private-but-unprivileged ioctls used by `ifconfig -v` (ifconfig has no entitlements, not setuid):
//  SIOCGIFLINKPARAMS (64-bit input/output effective+max bandwidth) and SIOCGIFLINKQUALITYMETRIC.
// Struct layouts copied from xnu bsd/net/if.h (PRIVATE section).
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
struct if_bandwidths { uint64_t eff_bw, max_bw; };
struct if_latencies { uint64_t eff_lt, max_lt; };
struct if_linkparamsreq {
    char iflpr_name[IFNAMSIZ];
    uint32_t iflpr_flags;
    uint32_t iflpr_output_sched;
    uint64_t iflpr_output_tbr_rate;
    uint32_t iflpr_output_tbr_percent;
    uint64_t iflpr_input_tbr_rate;
    struct if_bandwidths iflpr_output_bw;
    struct if_bandwidths iflpr_input_bw;
    struct if_latencies iflpr_output_lt;
    struct if_latencies iflpr_input_lt;
    uint8_t netem_params[112]; /* iflpr_input_netem + iflpr_output_netem (newer xnu); total size 224 = 0xe0 as encoded in /sbin/ifconfig's ioctl word 0xc0e069a8 */
};
#define SIOCGIFLINKPARAMS _IOWR('i', 168, struct if_linkparamsreq) /* 0xc0e069a8, found by disassembling /sbin/ifconfig */
#define SIOCGIFLINKQUALITYMETRIC _IOWR('i', 138, struct ifreq)
int main(int argc, char **argv) {
    const char *names[] = {"en0", "en1", "en2", "vmenet1", "bridge101", "utun4", "lo0"};
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    printf("sizeof(if_linkparamsreq)=%zu uid=%d\n", sizeof(struct if_linkparamsreq), getuid());
    for (int k = 0; k < 2; k++) {
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        struct if_linkparamsreq r; memset(&r, 0, sizeof r); strlcpy(r.iflpr_name, names[i], IFNAMSIZ);
        int rc = ioctl(s, SIOCGIFLINKPARAMS, &r);
        struct ifreq q; memset(&q, 0, sizeof q); strlcpy(q.ifr_name, names[i], IFNAMSIZ);
        int rc2 = ioctl(s, SIOCGIFLINKQUALITYMETRIC, &q);
        int lqm = *(int *)&q.ifr_ifru;
        printf("%-9s LINKPARAMS rc=%d%s sched=%u out eff=%llu max=%llu | in eff=%llu max=%llu | LQM rc=%d val=%d\n", names[i], rc, rc ? strerror(errno) : "",
               r.iflpr_output_sched, r.iflpr_output_bw.eff_bw, r.iflpr_output_bw.max_bw, r.iflpr_input_bw.eff_bw, r.iflpr_input_bw.max_bw, rc2, lqm);
    }
    if (!k) { printf("-- 3 s later\n"); sleep(3); }
    }
    return 0;
}
