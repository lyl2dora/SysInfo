// net_watch.c - 每秒读一次 IFMIB，打印指定接口及「全部非回环接口合计」的入/出字节差分（负差值记为 RESET，不钳 0）。
// build: xcrun clang -O2 -o net_watch net_watch.c
// usage: net_watch <seconds> <if1> [if2 ...]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_mib.h>
#define MAXI 128
static int rd(unsigned idx, unsigned long long *i, unsigned long long *o) {
    int m[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)idx, IFDATA_GENERAL}; struct ifmibdata md; size_t l = sizeof(md);
    if (sysctl(m, 6, &md, &l, NULL, 0)) return -1; *i = md.ifmd_data.ifi_ibytes; *o = md.ifmd_data.ifi_obytes; return 0;
}
int main(int argc, char **argv) {
    int S = atoi(argv[1]); int n = argc - 2;
    unsigned idx[MAXI]; unsigned long long pi[MAXI], po[MAXI], ti[MAXI] = {0}, to[MAXI] = {0};
    for (int k = 0; k < n; k++) { idx[k] = if_nametoindex(argv[k + 2]); rd(idx[k], &pi[k], &po[k]); }
    struct if_nameindex *ni = if_nameindex(); int na = 0; unsigned aidx[MAXI]; unsigned long long ai[MAXI], ao[MAXI];
    for (struct if_nameindex *p = ni; p && p->if_index && na < MAXI; p++) if (strcmp(p->if_name, "lo0")) { aidx[na] = p->if_index; rd(aidx[na], &ai[na], &ao[na]); na++; }
    unsigned long long tai = 0, tao = 0;
    printf("t");
    for (int k = 0; k < n; k++) printf("\t%s_in_MB\t%s_out_MB", argv[k + 2], argv[k + 2]);
    printf("\tall_in_MB\tall_out_MB\n");
    for (int s = 1; s <= S; s++) {
        sleep(1); printf("%d", s);
        for (int k = 0; k < n; k++) { unsigned long long i, o; rd(idx[k], &i, &o);
            if (i < pi[k] || o < po[k]) printf("\tRESET\tRESET"); else { printf("\t%.3f\t%.3f", (i - pi[k]) / 1e6, (o - po[k]) / 1e6); ti[k] += i - pi[k]; to[k] += o - po[k]; }
            pi[k] = i; po[k] = o; }
        unsigned long long di = 0, dO = 0;
        for (int a = 0; a < na; a++) { unsigned long long i, o; if (rd(aidx[a], &i, &o)) continue; if (i >= ai[a]) di += i - ai[a]; if (o >= ao[a]) dO += o - ao[a]; ai[a] = i; ao[a] = o; }
        tai += di; tao += dO; printf("\t%.3f\t%.3f\n", di / 1e6, dO / 1e6);
    }
    printf("total");
    for (int k = 0; k < n; k++) printf("\t%.3f\t%.3f", ti[k] / 1e6, to[k] / 1e6);
    printf("\t%.3f\t%.3f\n", tai / 1e6, tao / 1e6);
    return 0;
}
