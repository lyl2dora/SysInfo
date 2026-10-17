// costbench_net.c - 真实节奏（每 1 s 醒来一次）下网络模块各读取项的线程 CPU 开销（30 轮中位数）：
//   A) IFMIB 读主接口一次（sysctl IFDATA_GENERAL）
//   B) IFMIB 读全部接口（if_nameindex 枚举 + 逐个 sysctl）
//   C) 只枚举接口（if_nameindex），用于热插拔检测
//   D) getifaddrs（地址列表）
//   E) SCDynamicStore 读 Global/IPv4 + Global/DNS
//   F) IOKit 链路速率（IOBSDNameMatching + 父节点 IOLinkSpeed/IOLinkStatus）
//   G) SIOCGIFMEDIA
//   H) nettop 一次（posix_spawn + wait4，计子进程 user+sys），单独统计，只跑 5 轮
// build: xcrun clang -O2 -o costbench_net costbench_net.c -framework IOKit -framework CoreFoundation -framework SystemConfiguration
// usage: costbench_net <rounds> [primary-if]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <spawn.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <net/if.h>
#include <net/if_mib.h>
#include <net/if_media.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/network/IONetworkController.h>
#include <SystemConfiguration/SystemConfiguration.h>
extern char **environ;

static double tc(void) { struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts); return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6; }
static double wall(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6; }
static int cmpd(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
static volatile unsigned long long sink;
static const char *pif = "en0";

static void a_one(void) { unsigned idx = if_nametoindex(pif); int m[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)idx, IFDATA_GENERAL};
    struct ifmibdata md; size_t l = sizeof(md); sysctl(m, 6, &md, &l, NULL, 0); sink += md.ifmd_data.ifi_ibytes; }
static void b_all(void) { struct if_nameindex *ni = if_nameindex();
    for (struct if_nameindex *p = ni; p && p->if_index; p++) { int m[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)p->if_index, IFDATA_GENERAL};
        struct ifmibdata md; size_t l = sizeof(md); if (!sysctl(m, 6, &md, &l, NULL, 0)) sink += md.ifmd_data.ifi_ibytes; }
    if_freenameindex(ni); }
static void c_enum(void) { struct if_nameindex *ni = if_nameindex(); for (struct if_nameindex *p = ni; p && p->if_index; p++) sink += p->if_index; if_freenameindex(ni); }
static void d_ifaddrs(void) { struct ifaddrs *a; getifaddrs(&a); for (struct ifaddrs *p = a; p; p = p->ifa_next) sink++; freeifaddrs(a); }
static SCDynamicStoreRef st;
static void e_sc(void) { CFTypeRef a = SCDynamicStoreCopyValue(st, CFSTR("State:/Network/Global/IPv4")), b = SCDynamicStoreCopyValue(st, CFSTR("State:/Network/Global/DNS"));
    if (a) { sink++; CFRelease(a); } if (b) { sink++; CFRelease(b); } }
static void f_iokit(void) { io_service_t i = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, pif)); if (!i) return;
    io_registry_entry_t c = 0; IORegistryEntryGetParentEntry(i, kIOServicePlane, &c);
    if (c) { CFTypeRef s = IORegistryEntryCreateCFProperty(c, CFSTR(kIOLinkSpeed), 0, 0), t = IORegistryEntryCreateCFProperty(c, CFSTR(kIOLinkStatus), 0, 0);
        if (s) { sink++; CFRelease(s); } if (t) { sink++; CFRelease(t); } IOObjectRelease(c); }
    IOObjectRelease(i); }
static void g_media(void) { int s = socket(AF_INET, SOCK_DGRAM, 0); struct ifmediareq r; memset(&r, 0, sizeof(r)); strlcpy(r.ifm_name, pif, sizeof(r.ifm_name));
    ioctl(s, SIOCGIFMEDIA, &r); sink += r.ifm_active; close(s); }

typedef void (*fn)(void);
int main(int argc, char **argv) {
    int R = argc > 1 ? atoi(argv[1]) : 30; if (argc > 2) pif = argv[2];
    st = SCDynamicStoreCreate(NULL, CFSTR("costbench"), NULL, NULL);
    struct if_nameindex *ni = if_nameindex(); int nif = 0; for (struct if_nameindex *p = ni; p && p->if_index; p++) nif++; if_freenameindex(ni);
    printf("interfaces=%d primary=%s rounds=%d\n", nif, pif, R);
    fn fs[] = {a_one, b_all, c_enum, d_ifaddrs, e_sc, f_iokit, g_media};
    const char *nm[] = {"A IFMIB primary", "B IFMIB all", "C if_nameindex", "D getifaddrs", "E SCDynamicStore x2", "F IOKit link speed", "G SIOCGIFMEDIA"};
    int K = 7; double *v = calloc(K * R, sizeof(double));
    for (int k = 0; k < K; k++) fs[k]();  // 预热
    for (int r = 0; r < R; r++) { sleep(1); for (int k = 0; k < K; k++) { double t0 = tc(); fs[k](); v[k * R + r] = tc() - t0; } }
    for (int k = 0; k < K; k++) { qsort(v + k * R, R, sizeof(double), cmpd); printf("%-22s median=%.4f ms  p90=%.4f ms\n", nm[k], v[k * R + R / 2], v[k * R + R * 9 / 10]); }
    // H) nettop
    double nt[5], nw[5];
    for (int r = 0; r < 5; r++) {
        sleep(1);
        char *args[] = {"/usr/bin/nettop", "-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out", NULL};
        posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa); posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
        double w0 = wall(), t0 = tc(); pid_t pid; posix_spawn(&pid, args[0], &fa, NULL, args, environ);
        int stt; struct rusage ru; wait4(pid, &stt, 0, &ru); double t1 = tc(), w1 = wall();
        nt[r] = ru.ru_utime.tv_sec * 1e3 + ru.ru_utime.tv_usec / 1e3 + ru.ru_stime.tv_sec * 1e3 + ru.ru_stime.tv_usec / 1e3 + (t1 - t0);
        nw[r] = w1 - w0; posix_spawn_file_actions_destroy(&fa);
    }
    qsort(nt, 5, sizeof(double), cmpd); qsort(nw, 5, sizeof(double), cmpd);
    printf("%-22s median=%.2f ms CPU (child user+sys + spawn)  wall=%.1f ms\n", "H nettop -L1", nt[2], nw[2]);
    return 0;
}
