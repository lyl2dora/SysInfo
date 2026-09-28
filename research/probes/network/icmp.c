// Probe: unprivileged ICMP echo via SOCK_DGRAM (IPv4 IPPROTO_ICMP and IPv6 IPPROTO_ICMPV6), no root.
// Checks: socket creation, RTT, whether recv() data includes the IPv4 header (Stats' validateResponse assumes it does).
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <netinet/icmp6.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netdb.h>
#include <mach/mach_time.h>

static unsigned short cksum(const void *d, int len) {
    const unsigned short *w = d; unsigned sum = 0;
    for (; len > 1; len -= 2) sum += *w++;
    if (len) sum += *(const unsigned char *)w;
    sum = (sum >> 16) + (sum & 0xffff); sum += sum >> 16; return (unsigned short)~sum;
}
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }

static void ping4(const char *host, int count) {
    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (s < 0) { printf("v4 %s socket error: %s\n", host, strerror(errno)); return; }
    struct timeval tv = {2, 0}; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET}; inet_pton(AF_INET, host, &to.sin_addr);
    for (int seq = 0; seq < count; seq++) {
        unsigned char pkt[64] = {0}; struct icmp *ic = (struct icmp *)pkt;
        ic->icmp_type = ICMP_ECHO; ic->icmp_id = htons(0x1234); ic->icmp_seq = htons(seq); memcpy(pkt + 8, "stats-probe", 11);
        ic->icmp_cksum = cksum(pkt, sizeof(pkt));
        double t0 = now_ms();
        if (sendto(s, pkt, sizeof(pkt), 0, (struct sockaddr *)&to, sizeof(to)) < 0) { printf("v4 %s sendto error: %s\n", host, strerror(errno)); break; }
        unsigned char buf[1500]; ssize_t n = recv(s, buf, sizeof(buf), 0); double t1 = now_ms();
        if (n < 0) { printf("v4 %s seq=%d recv error: %s\n", host, seq, strerror(errno)); continue; }
        int hasIP = (buf[0] & 0xF0) == 0x40; int hl = hasIP ? (buf[0] & 0x0F) * 4 : 0;
        struct icmp *r = (struct icmp *)(buf + hl);
        printf("v4 %-15s seq=%d bytes=%zd includesIPHeader=%d ttl=%d type=%d code=%d id=0x%04x rtt=%.3f ms\n", host, seq, n, hasIP, hasIP ? buf[8] : -1, r->icmp_type, r->icmp_code, ntohs(r->icmp_id), t1 - t0);
        usleep(200000);
    }
    close(s);
}

static void ping6(const char *host, int count) {
    int s = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6);
    if (s < 0) { printf("v6 %s socket error: %s\n", host, strerror(errno)); return; }
    struct timeval tv = {2, 0}; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct addrinfo hints = {.ai_family = AF_INET6, .ai_socktype = SOCK_DGRAM}, *ai = NULL;
    if (getaddrinfo(host, NULL, &hints, &ai) || !ai) { printf("v6 %s resolve failed\n", host); close(s); return; }
    for (int seq = 0; seq < count; seq++) {
        unsigned char pkt[64] = {0}; struct icmp6_hdr *ic = (struct icmp6_hdr *)pkt;
        ic->icmp6_type = ICMP6_ECHO_REQUEST; ic->icmp6_id = htons(0x4321); ic->icmp6_seq = htons(seq); // kernel computes ICMPv6 checksum
        double t0 = now_ms();
        if (sendto(s, pkt, sizeof(pkt), 0, ai->ai_addr, ai->ai_addrlen) < 0) { printf("v6 %s sendto error: %s\n", host, strerror(errno)); break; }
        unsigned char buf[1500]; ssize_t n = recv(s, buf, sizeof(buf), 0); double t1 = now_ms();
        if (n < 0) { printf("v6 %s seq=%d recv error: %s\n", host, seq, strerror(errno)); continue; }
        struct icmp6_hdr *r = (struct icmp6_hdr *)buf;
        printf("v6 %-22s seq=%d bytes=%zd type=%d code=%d id=0x%04x rtt=%.3f ms\n", host, seq, n, r->icmp6_type, r->icmp6_code, ntohs(r->icmp6_id), t1 - t0);
        usleep(200000);
    }
    freeaddrinfo(ai); close(s);
}

int main(void) {
    printf("uid=%d euid=%d\n", getuid(), geteuid());
    ping4("192.0.2.1", 3);
    ping4("1.1.1.1", 3);
    ping6("2606:4700:4700::1111", 3);
    // raw socket for comparison (expected EPERM without root)
    int r = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    printf("SOCK_RAW ICMP: %s\n", r < 0 ? strerror(errno) : "opened (unexpected)"); if (r >= 0) close(r);
    return 0;
}
