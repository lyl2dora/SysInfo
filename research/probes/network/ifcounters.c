// Probe: interface byte/packet counters.
// Compares (a) getifaddrs AF_LINK ifa_data (struct if_data, 32-bit counters, what Stats uses for status/baudrate)
//          (b) sysctl NET_RT_IFLIST2 -> if_msghdr2.ifm_data (struct if_data64, what Stats uses for bytes)
//          (c) sysctl net.link.generic.ifdata.<idx>.general -> struct ifmibdata.ifmd_data (if_data64)
// Two samples, 2 s apart, to confirm counters advance.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_mib.h>
#include <net/if_types.h>
#include <net/route.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/types.h>

typedef struct {
    char name[IFNAMSIZ];
    unsigned idx;
    unsigned long long ib32, ob32, ip32, op32, baud32;
    unsigned long long ib64, ob64, ip64, op64, baud64, ierr, oerr, coll, imcast, omcast, iqdrops;
    unsigned long long mib_ib, mib_ob, mib_baud;
    unsigned type;
    int up, running;
} row_t;

static int collect(row_t *rows, int max) {
    int n = 0;
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) { perror("getifaddrs"); return 0; }
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || !p->ifa_data) continue;
        if (n >= max) break;
        struct if_data *d = (struct if_data *)p->ifa_data;
        row_t *r = &rows[n++];
        memset(r, 0, sizeof(*r));
        strlcpy(r->name, p->ifa_name, sizeof(r->name));
        r->idx = if_nametoindex(p->ifa_name);
        r->ib32 = d->ifi_ibytes; r->ob32 = d->ifi_obytes; r->ip32 = d->ifi_ipackets; r->op32 = d->ifi_opackets;
        r->baud32 = d->ifi_baudrate;
        r->up = (p->ifa_flags & IFF_UP) != 0; r->running = (p->ifa_flags & IFF_RUNNING) != 0;
    }
    freeifaddrs(ifa);

    // NET_RT_IFLIST2 for all interfaces (index 0)
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0) { perror("sysctl IFLIST2 size"); return n; }
    char *buf = malloc(len);
    if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) { perror("sysctl IFLIST2"); free(buf); return n; }
    for (char *next = buf; next < buf + len;) {
        struct if_msghdr *ifm = (struct if_msghdr *)next;
        if (ifm->ifm_msglen == 0) break;
        if (ifm->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *m2 = (struct if_msghdr2 *)next;
            for (int i = 0; i < n; i++) if (rows[i].idx == m2->ifm_index) {
                rows[i].ib64 = m2->ifm_data.ifi_ibytes; rows[i].ob64 = m2->ifm_data.ifi_obytes;
                rows[i].ip64 = m2->ifm_data.ifi_ipackets; rows[i].op64 = m2->ifm_data.ifi_opackets;
                rows[i].baud64 = m2->ifm_data.ifi_baudrate; rows[i].ierr = m2->ifm_data.ifi_ierrors;
                rows[i].oerr = m2->ifm_data.ifi_oerrors; rows[i].coll = m2->ifm_data.ifi_collisions;
                rows[i].imcast = m2->ifm_data.ifi_imcasts; rows[i].omcast = m2->ifm_data.ifi_omcasts;
                rows[i].iqdrops = m2->ifm_data.ifi_iqdrops; rows[i].type = m2->ifm_data.ifi_type;
            }
        }
        next += ifm->ifm_msglen;
    }
    free(buf);

    // net.link.generic.ifdata.<idx>.general
    for (int i = 0; i < n; i++) {
        int m[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)rows[i].idx, IFDATA_GENERAL};
        struct ifmibdata md; size_t l = sizeof(md);
        if (sysctl(m, 6, &md, &l, NULL, 0) == 0) {
            rows[i].mib_ib = md.ifmd_data.ifi_ibytes; rows[i].mib_ob = md.ifmd_data.ifi_obytes;
            rows[i].mib_baud = md.ifmd_data.ifi_baudrate;
        }
    }
    return n;
}

int main(void) {
    row_t a[128], b[128];
    printf("sizeof(if_data)=%zu sizeof(if_data64)=%zu sizeof(if_msghdr2)=%zu\n", sizeof(struct if_data), sizeof(struct if_data64), sizeof(struct if_msghdr2));
    int na = collect(a, 128);
    sleep(2);
    int nb = collect(b, 128);
    printf("%-10s %4s %4s %2s %-22s %-22s %-14s %-14s %-14s %-12s\n", "if", "idx", "type", "UR", "ibytes32 / ibytes64", "obytes32 / obytes64", "baud32", "baud64", "mib_baud", "wrapped?");
    for (int i = 0; i < na && i < nb; i++) {
        row_t *r = &b[i];
        int wrapped = (r->ib64 > 0xFFFFFFFFULL) || (r->ob64 > 0xFFFFFFFFULL);
        printf("%-10s %4u %4u %d%d %10llu/%-12llu %10llu/%-12llu %-14llu %-14llu %-14llu %s\n", r->name, r->idx, r->type, r->up, r->running,
               r->ib32, r->ib64, r->ob32, r->ob64, r->baud32, r->baud64, r->mib_baud,
               wrapped ? ((r->ib32 == (r->ib64 & 0xFFFFFFFFULL)) ? "YES(32=lo32 of 64)" : "YES(mismatch)") : "no");
    }
    printf("\nDelta over 2 s (64-bit IFLIST2) and pkt/err detail:\n");
    for (int i = 0; i < na && i < nb; i++) {
        if (strcmp(a[i].name, b[i].name)) continue;
        long long di = (long long)(b[i].ib64 - a[i].ib64), dout = (long long)(b[i].ob64 - a[i].ob64);
        long long di32 = (long long)(b[i].ib32 - a[i].ib32), dmib = (long long)(b[i].mib_ib - a[i].mib_ib);
        if (di == 0 && dout == 0 && b[i].ib64 == 0) continue;
        printf("%-10s dIn64=%-10lld dOut64=%-10lld dIn32=%-10lld dInMIB=%-10lld ipkts=%llu opkts=%llu ierr=%llu oerr=%llu coll=%llu imcast=%llu omcast=%llu iqdrops=%llu\n",
               b[i].name, di, dout, di32, dmib, b[i].ip64, b[i].op64, b[i].ierr, b[i].oerr, b[i].coll, b[i].imcast, b[i].omcast, b[i].iqdrops);
    }
    return 0;
}
