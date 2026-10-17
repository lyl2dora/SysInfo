// icmp_app.c - K47：签名 .app（Developer ID，独立 responsible process）里发 ICMP 是否触发「本地网络」授权。
// 模式：icmp <目标...>  对每个目标发 5 个 ICMP echo（SOCK_DGRAM，非 root）；
//       tcp  <目标>     阳性对照二：TCP 连接目标 80 端口；
//       udp  <目标>     作为阳性对照，向目标的 UDP 9 端口（discard）发 3 个包（局域网 UDP 应触发授权）。
// 结果追加写到 ~/Library/Caches/zone.lyl.sysinfo.probe.icmp/result.txt（app 由 open 启动，没有终端）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <mach/mach_time.h>

static FILE *out;
static unsigned short ck(const void *d, int n) { const unsigned short *w = d; unsigned s = 0; for (; n > 1; n -= 2) s += *w++; if (n) s += *(const unsigned char *)w; s = (s >> 16) + (s & 0xffff); s += s >> 16; return (unsigned short)~s; }
static double ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }

static void icmp(const char *host) {
    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (s < 0) { fprintf(out, "icmp %s socket: %s\n", host, strerror(errno)); return; }
    struct timeval tv = {2, 0}; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET}; inet_pton(AF_INET, host, &to.sin_addr);
    int ok = 0; double sum = 0;
    for (int q = 0; q < 5; q++) {
        unsigned char p[64] = {0}; struct icmp *ic = (struct icmp *)p; ic->icmp_type = ICMP_ECHO; ic->icmp_id = htons(0x5150); ic->icmp_seq = htons(q); ic->icmp_cksum = ck(p, 64);
        double t0 = ms();
        if (sendto(s, p, 64, 0, (struct sockaddr *)&to, sizeof(to)) < 0) { fprintf(out, "icmp %s seq=%d sendto: %s (errno %d)\n", host, q, strerror(errno), errno); sleep(1); continue; }
        unsigned char b[1500]; ssize_t n = recv(s, b, sizeof(b), 0); double t1 = ms();
        if (n < 0) { fprintf(out, "icmp %s seq=%d recv: %s\n", host, q, strerror(errno)); continue; }
        int hl = ((b[0] & 0xF0) == 0x40) ? (b[0] & 0x0F) * 4 : 0; struct icmp *r = (struct icmp *)(b + hl);
        fprintf(out, "icmp %s seq=%d type=%d ttl=%d rtt=%.3f ms\n", host, q, r->icmp_type, hl ? b[8] : -1, t1 - t0); ok++; sum += t1 - t0;
        usleep(300000);
    }
    fprintf(out, "icmp %s summary ok=%d/5 avg=%.3f ms\n", host, ok, ok ? sum / ok : 0);
    close(s);
}
static void udp(const char *host) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(9)}; inet_pton(AF_INET, host, &to.sin_addr);
    for (int q = 0; q < 3; q++) { ssize_t r = sendto(s, "x", 1, 0, (struct sockaddr *)&to, sizeof(to));
        fprintf(out, "udp %s seq=%d sendto=%zd %s\n", host, q, r, r < 0 ? strerror(errno) : ""); sleep(2); }
    close(s);
}
static void tcp(const char *host) {
    // 阳性对照二：向局域网主机 80 端口发起 TCP 连接（拒绝 / 超时都算网络可达；EHOSTUNREACH 视为被本地网络隐私拦截）
    int s = socket(AF_INET, SOCK_STREAM, 0); struct timeval tv = {3, 0}; setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(80)}; inet_pton(AF_INET, host, &to.sin_addr);
    double t0 = ms(); int r = connect(s, (struct sockaddr *)&to, sizeof(to)); int e = errno;
    fprintf(out, "tcp %s:80 connect=%d %s (errno %d) %.1f ms\n", host, r, r ? strerror(e) : "ok", r ? e : 0, ms() - t0); close(s);
}
int main(int argc, char **argv) {
    char path[1024]; snprintf(path, sizeof(path), "%s/Library/Caches/zone.lyl.sysinfo.probe.icmp", getenv("HOME")); mkdir(path, 0755);
    strlcat(path, "/result.txt", sizeof(path)); out = fopen(path, "a"); setvbuf(out, NULL, _IOLBF, 0);
    time_t t = time(NULL); fprintf(out, "--- run %s", ctime(&t));
    if (argc < 3) { fprintf(out, "usage: icmp|udp hosts...\n"); return 1; }
    for (int i = 2; i < argc; i++) { if (!strcmp(argv[1], "udp")) udp(argv[i]); else if (!strcmp(argv[1], "tcp")) tcp(argv[i]); else icmp(argv[i]); }
    fprintf(out, "--- done\n"); return 0;
}
