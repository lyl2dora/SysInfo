// net_struct.c - 网络模块结构比对（只读）：逐接口列出 IFMIB 类型/标志/计数、IOKit 背后的控制器、
// 内置标志、链路速率与状态、SIOCGIFMEDIA、SCNetworkInterface 类型、是否有 IPv4 / 全局 IPv6 地址（只输出有无，不输出地址），
// 以及 SCDynamicStore 的主接口。不输出 MAC、IP、SSID 等设备标识。
// build: xcrun clang -O2 -o net_struct net_struct.c -framework IOKit -framework CoreFoundation -framework SystemConfiguration
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <netinet6/in6_var.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_mib.h>
#include <net/if_media.h>
#include <net/if_types.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/network/IONetworkInterface.h>
#include <IOKit/network/IONetworkController.h>
#include <SystemConfiguration/SystemConfiguration.h>

static void cs(CFStringRef s, char *b, int n) { b[0] = 0; if (s) CFStringGetCString(s, b, n, kCFStringEncodingUTF8); }
static long long num(CFTypeRef v) { long long x = -1; if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongLongType, &x); return x; }
static int boolv(CFTypeRef v) { if (!v) return -1; if (CFGetTypeID(v) == CFBooleanGetTypeID()) return CFBooleanGetValue(v); return (int)num(v); }

static int ifmib(unsigned idx, struct ifmibdata *md) {
    int m[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)idx, IFDATA_GENERAL};
    size_t l = sizeof(*md); memset(md, 0, sizeof(*md)); return sysctl(m, 6, md, &l, NULL, 0);
}

static void media(const char *ifn, char *out, int n) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifmediareq r; memset(&r, 0, sizeof(r)); strlcpy(r.ifm_name, ifn, sizeof(r.ifm_name));
    if (ioctl(s, SIOCGIFMEDIA, &r) < 0) { snprintf(out, n, "-"); close(s); return; }
    int a = r.ifm_active; const char *st = "other";
    if (IFM_TYPE(a) == IFM_ETHER) switch (IFM_SUBTYPE(a)) {
        case IFM_10_T: st = "10T"; break; case IFM_100_TX: st = "100TX"; break; case IFM_1000_T: st = "1000T"; break;
        case IFM_2500_T: st = "2.5GT"; break; case IFM_5000_T: st = "5GT"; break; case IFM_10G_T: st = "10GT"; break;
        case IFM_AUTO: st = "auto"; break; case IFM_NONE: st = "none"; break; }
    else if (IFM_TYPE(a) == IFM_IEEE80211) st = "80211";
    snprintf(out, n, "%s%s/%s", (r.ifm_status & IFM_AVALID) ? "" : "?", (r.ifm_status & IFM_ACTIVE) ? "active" : "inactive", st);
    close(s);
}

static void iokit(const char *ifn, char *out, int n) {
    io_service_t intf = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, ifn));
    if (!intf) { snprintf(out, n, "(no IONetworkInterface)"); return; }
    io_name_t cls, ccls = ""; IOObjectGetClass(intf, cls);
    io_registry_entry_t ctrl = 0; IORegistryEntryGetParentEntry(intf, kIOServicePlane, &ctrl);
    if (ctrl) IOObjectGetClass(ctrl, ccls);
    CFTypeRef b = IORegistryEntryCreateCFProperty(intf, CFSTR(kIOBuiltin), 0, 0);
    CFTypeRef p = IORegistryEntryCreateCFProperty(intf, CFSTR(kIOPrimaryInterface), 0, 0);
    CFTypeRef t = IORegistryEntryCreateCFProperty(intf, CFSTR(kIOInterfaceType), 0, 0);
    CFTypeRef sp = ctrl ? IORegistryEntryCreateCFProperty(ctrl, CFSTR(kIOLinkSpeed), 0, 0) : NULL;
    CFTypeRef ls = ctrl ? IORegistryEntryCreateCFProperty(ctrl, CFSTR(kIOLinkStatus), 0, 0) : NULL;
    snprintf(out, n, "intf=%s ctrl=%s builtin=%d primary=%d ifType=%lld linkSpeed=%.0fMbps linkStatus=0x%llx",
             cls, ccls, boolv(b), boolv(p), num(t), num(sp) < 0 ? -1.0 : num(sp) / 1e6, num(ls) < 0 ? 0 : num(ls));
    if (b) CFRelease(b); if (p) CFRelease(p); if (t) CFRelease(t); if (sp) CFRelease(sp); if (ls) CFRelease(ls);
    if (ctrl) IOObjectRelease(ctrl); IOObjectRelease(intf);
}

int main(void) {
    // SCNetworkInterface 类型表
    CFArrayRef all = SCNetworkInterfaceCopyAll();
    // 主接口
    SCDynamicStoreRef st = SCDynamicStoreCreate(NULL, CFSTR("net_struct"), NULL, NULL);
    char prim4[32] = "-", prim6[32] = "-";
    CFDictionaryRef g4 = SCDynamicStoreCopyValue(st, CFSTR("State:/Network/Global/IPv4"));
    CFDictionaryRef g6 = SCDynamicStoreCopyValue(st, CFSTR("State:/Network/Global/IPv6"));
    if (g4) cs(CFDictionaryGetValue(g4, CFSTR("PrimaryInterface")), prim4, 32);
    if (g6) cs(CFDictionaryGetValue(g6, CFSTR("PrimaryInterface")), prim6, 32);
    printf("primary IPv4=%s IPv6=%s\n", prim4, prim6);

    struct ifaddrs *ifa = NULL; getifaddrs(&ifa);
    struct if_nameindex *ni = if_nameindex();
    printf("%-10s %3s %4s %-5s %-22s %-14s %-12s %6s %6s %6s %6s %s\n", "if", "idx", "type", "flags", "SC type", "media", "addr", "ibytes", "obytes", "ierrs", "iqdrop", "IOKit");
    for (struct if_nameindex *p = ni; p && p->if_index; p++) {
        struct ifmibdata md; if (ifmib(p->if_index, &md)) { printf("%-10s ifmib error\n", p->if_name); continue; }
        char sct[64] = "-";
        for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) {
            SCNetworkInterfaceRef s = CFArrayGetValueAtIndex(all, i); char bn[32]; cs(SCNetworkInterfaceGetBSDName(s), bn, 32);
            if (!strcmp(bn, p->if_name)) { cs(SCNetworkInterfaceGetInterfaceType(s), sct, 64); break; }
        }
        int v4 = 0, v6g = 0, v6ll = 0;
        for (struct ifaddrs *a = ifa; a; a = a->ifa_next) {
            if (!a->ifa_addr || strcmp(a->ifa_name, p->if_name)) continue;
            if (a->ifa_addr->sa_family == AF_INET) v4 = 1;
            if (a->ifa_addr->sa_family == AF_INET6) { struct in6_addr *x = &((struct sockaddr_in6 *)a->ifa_addr)->sin6_addr;
                if (IN6_IS_ADDR_LINKLOCAL(x)) v6ll = 1; else if (!IN6_IS_ADDR_LOOPBACK(x)) v6g = 1; }
        }
        char addr[16]; snprintf(addr, 16, "%s%s%s", v4 ? "v4 " : "", v6g ? "v6g " : "", v6ll ? "ll" : "");
        char me[32]; media(p->if_name, me, 32);
        char io[256]; iokit(p->if_name, io, 256);
        unsigned fl = md.ifmd_flags;
        char fs[8]; snprintf(fs, 8, "%c%c%c", (fl & IFF_UP) ? 'U' : '-', (fl & IFF_RUNNING) ? 'R' : '-', (fl & IFF_POINTOPOINT) ? 'P' : '-');
        printf("%-10s %3u %4u %-5s %-22s %-14s %-12s %6s %6s %6llu %6llu %s\n", p->if_name, p->if_index, md.ifmd_data.ifi_type, fs, sct, me, addr,
               md.ifmd_data.ifi_ibytes ? "nz" : "0", md.ifmd_data.ifi_obytes ? "nz" : "0",
               (unsigned long long)md.ifmd_data.ifi_ierrors, (unsigned long long)md.ifmd_data.ifi_iqdrops, io);
    }
    if_freenameindex(ni); freeifaddrs(ifa);
    return 0;
}
