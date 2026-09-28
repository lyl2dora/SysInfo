// Probe: link speed for interfaces whose ifi_baudrate saturates at UINT32_MAX.
// (a) SIOCGIFMEDIA active media word -> subtype decode
// (b) IOKit: IONetworkController "IOLinkSpeed" (64-bit bps) + IOLinkStatus, matched by BSD name via IONetworkInterface
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <net/if_media.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/network/IONetworkInterface.h>
#include <IOKit/network/IONetworkController.h>

static void media(const char *ifn) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifmediareq ifmr; memset(&ifmr, 0, sizeof(ifmr)); strlcpy(ifmr.ifm_name, ifn, sizeof(ifmr.ifm_name));
    if (ioctl(s, SIOCGIFMEDIA, &ifmr) < 0) { printf("%s SIOCGIFMEDIA failed\n", ifn); close(s); return; }
    int a = ifmr.ifm_active;
    const char *st = "?";
    if (IFM_TYPE(a) == IFM_ETHER) {
        switch (IFM_SUBTYPE(a)) {
            case IFM_10_T: st = "10baseT"; break; case IFM_100_TX: st = "100baseTX"; break; case IFM_1000_T: st = "1000baseT"; break;
            case IFM_2500_T: st = "2500baseT"; break; case IFM_5000_T: st = "5000baseT"; break; case IFM_10G_T: st = "10GbaseT"; break;
            case IFM_AUTO: st = "autoselect"; break; case IFM_NONE: st = "none"; break; default: st = "other"; }
    } else if (IFM_TYPE(a) == IFM_IEEE80211) st = "ieee80211";
    printf("%-6s SIOCGIFMEDIA status=0x%x active=0x%x type=0x%x subtype=%d(%s) fdx=%d\n", ifn, ifmr.ifm_status, a, IFM_TYPE(a), IFM_SUBTYPE(a), st, (a & IFM_FDX) != 0);
    close(s);
}

static void iokit(const char *ifn) {
    CFMutableDictionaryRef m = IOBSDNameMatching(kIOMainPortDefault, 0, ifn);
    io_service_t intf = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!intf) { printf("%-6s IOKit: no IONetworkInterface\n", ifn); return; }
    io_name_t cls; IOObjectGetClass(intf, cls);
    io_registry_entry_t ctrl = 0;
    IORegistryEntryGetParentEntry(intf, kIOServicePlane, &ctrl);
    io_name_t ccls = ""; if (ctrl) IOObjectGetClass(ctrl, ccls);
    CFTypeRef sp = ctrl ? IORegistryEntryCreateCFProperty(ctrl, CFSTR(kIOLinkSpeed), kCFAllocatorDefault, 0) : NULL;
    CFTypeRef ls = ctrl ? IORegistryEntryCreateCFProperty(ctrl, CFSTR(kIOLinkStatus), kCFAllocatorDefault, 0) : NULL;
    long long speed = -1; int status = -1;
    if (sp && CFGetTypeID(sp) == CFNumberGetTypeID()) CFNumberGetValue(sp, kCFNumberLongLongType, &speed);
    if (ls && CFGetTypeID(ls) == CFNumberGetTypeID()) CFNumberGetValue(ls, kCFNumberIntType, &status);
    // also try searching parents recursively
    if (speed < 0) {
        CFTypeRef sp2 = IORegistryEntrySearchCFProperty(intf, kIOServicePlane, CFSTR(kIOLinkSpeed), kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
        if (sp2 && CFGetTypeID(sp2) == CFNumberGetTypeID()) CFNumberGetValue(sp2, kCFNumberLongLongType, &speed);
        if (sp2) CFRelease(sp2);
    }
    printf("%-6s IOKit intf=%s ctrl=%s IOLinkSpeed=%lld bps (%.1f Mbps) IOLinkStatus=0x%x\n", ifn, cls, ccls, speed, speed / 1e6, status);
    if (sp) CFRelease(sp); if (ls) CFRelease(ls);
    if (ctrl) IOObjectRelease(ctrl); IOObjectRelease(intf);
}

int main(void) {
    const char *names[] = {"en0", "en1", "en2", "vmenet1", "bridge101"};
    for (int i = 0; i < 5; i++) { media(names[i]); iokit(names[i]); }
    return 0;
}
