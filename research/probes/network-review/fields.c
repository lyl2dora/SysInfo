// Review probe: field-by-field comparison of NET_RT_IFLIST2 if_data64 vs IFMIB ifmibdata.ifmd_data
// at (nearly) the same instant, for every interface. Flags fields that differ.
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <net/if.h>
#include <net/if_mib.h>
#include <net/route.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#define F(x) {#x, offsetof(struct if_data64, x)}
struct fd { const char *n; size_t off; } fields[] = {
  F(ifi_baudrate), F(ifi_ipackets), F(ifi_ierrors), F(ifi_opackets), F(ifi_oerrors), F(ifi_collisions),
  F(ifi_ibytes), F(ifi_obytes), F(ifi_imcasts), F(ifi_omcasts), F(ifi_iqdrops), F(ifi_noproto)};
int main(void) {
  int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
  size_t len = 0; sysctl(mib, 6, NULL, &len, NULL, 0);
  char *buf = malloc(len); if (sysctl(mib, 6, buf, &len, NULL, 0)) { perror("iflist2"); return 1; }
  for (char *p = buf; p < buf + len;) {
    struct if_msghdr *h = (void *)p; if (!h->ifm_msglen) break;
    if (h->ifm_type == RTM_IFINFO2) {
      struct if_msghdr2 *m = (void *)p;
      struct ifmibdata md; size_t l = sizeof md;
      int mm[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, m->ifm_index, IFDATA_GENERAL};
      if (sysctl(mm, 6, &md, &l, NULL, 0)) { perror("ifmib"); p += h->ifm_msglen; continue; }
      printf("%-10s idx=%-3u mtu=%u/%u", md.ifmd_name, m->ifm_index, m->ifm_data.ifi_mtu, md.ifmd_data.ifi_mtu);
      for (size_t i = 0; i < sizeof fields / sizeof *fields; i++) {
        unsigned long long a = *(u_int64_t *)((char *)&m->ifm_data + fields[i].off);
        unsigned long long b = *(u_int64_t *)((char *)&md.ifmd_data + fields[i].off);
        if (a || b) printf(" %s=%llu%s%llu", fields[i].n + 4, a, a == b ? "==" : "!=", b);
      }
      printf("\n");
    }
    p += h->ifm_msglen;
  }
  return 0;
}
