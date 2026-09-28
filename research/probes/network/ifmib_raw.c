// Probe: raw values from each counter path for en0/en1/lo0, printed side by side with netstat semantics.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_mib.h>
#include <net/route.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
static void iflist2(unsigned idx, unsigned long long *ib, unsigned long long *ob, int per_if) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, per_if ? (int)idx : 0};
    size_t len = 0; *ib = *ob = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0)) return;
    char *buf = malloc(len); if (sysctl(mib, 6, buf, &len, NULL, 0)) { free(buf); return; }
    for (char *n = buf; n < buf + len;) { struct if_msghdr *h = (void*)n; if (!h->ifm_msglen) break;
        if (h->ifm_type == RTM_IFINFO2) { struct if_msghdr2 *m = (void*)n; if (m->ifm_index == idx) { *ib = m->ifm_data.ifi_ibytes; *ob = m->ifm_data.ifi_obytes; } }
        n += h->ifm_msglen; }
    free(buf);
}
static void iflist(unsigned idx, unsigned long long *ib, unsigned long long *ob) {
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST, 0};
    size_t len = 0; *ib = *ob = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0)) return;
    char *buf = malloc(len); if (sysctl(mib, 6, buf, &len, NULL, 0)) { free(buf); return; }
    for (char *n = buf; n < buf + len;) { struct if_msghdr *h = (void*)n; if (!h->ifm_msglen) break;
        if (h->ifm_type == RTM_IFINFO && h->ifm_index == idx) { *ib = h->ifm_data.ifi_ibytes; *ob = h->ifm_data.ifi_obytes; }
        n += h->ifm_msglen; }
    free(buf);
}
static void ifmib(unsigned idx, struct ifmibdata *md) {
    int m[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)idx, IFDATA_GENERAL};
    size_t l = sizeof(*md); memset(md, 0, sizeof(*md)); if (sysctl(m, 6, md, &l, NULL, 0)) perror("ifmib");
}
int main(void) {
    const char *names[] = {"en0", "en1", "lo0", "bridge101", "vmenet1"};
    for (int s = 0; s < 2; s++) {
        printf("--- sample %d\n", s);
        for (int i = 0; i < 5; i++) {
            unsigned idx = if_nametoindex(names[i]);
            unsigned long long a, b, c, d, e, f; struct ifmibdata md;
            iflist2(idx, &a, &b, 0); iflist2(idx, &e, &f, 1); iflist(idx, &c, &d); ifmib(idx, &md);
            printf("%-9s IFLIST2(all) in=%llu out=%llu | IFLIST2(idx) in=%llu out=%llu | IFLIST(32) in=%llu out=%llu | IFMIB in=%llu out=%llu ipk=%llu opk=%llu baud=%llu name=%s snd_len=%u snd_maxlen=%u snd_drops=%u\n",
                   names[i], a, b, e, f, c, d, (unsigned long long)md.ifmd_data.ifi_ibytes, (unsigned long long)md.ifmd_data.ifi_obytes,
                   (unsigned long long)md.ifmd_data.ifi_ipackets, (unsigned long long)md.ifmd_data.ifi_opackets,
                   (unsigned long long)md.ifmd_data.ifi_baudrate, md.ifmd_name, md.ifmd_snd_len, md.ifmd_snd_maxlen, md.ifmd_snd_drops);
        }
        if (!s) sleep(1);
    }
    return 0;
}
