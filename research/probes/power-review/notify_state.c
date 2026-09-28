// notify_state.c — REVIEW probe (read-only): decode the bit-packed notify(3) state of the power-source
// channels and compare with IOPS Time to Empty / Current Capacity at the same instant.
#include <notify.h>
#include <stdio.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
static uint64_t st(const char *k) { int t; uint64_t s = 0; if (notify_register_check(k, &t) == NOTIFY_STATUS_OK) { notify_get_state(t, &s); notify_cancel(t); } return s; }
int main(void) {
    const char *ks[] = {"com.apple.system.powersources.timeremaining", "com.apple.system.powersources.percent", "com.apple.system.powersources.source", "com.apple.system.accpowersources.percent", "com.apple.system.accpowersources.timeremaining"};
    for (int i = 0; i < 5; i++) { uint64_t s = st(ks[i]); printf("%-48s state=0x%016llx  low16=%llu  bits16-23=0x%02llx  top8=0x%02llx\n", ks[i], s, s & 0xffff, (s >> 16) & 0xff, s >> 56); }
    CFTypeRef b = IOPSCopyPowerSourcesInfo(); CFArrayRef l = IOPSCopyPowerSourcesList(b);
    CFDictionaryRef d = IOPSGetPowerSourceDescription(b, CFArrayGetValueAtIndex(l, 0));
    int tte = -1, cap = -1; CFNumberGetValue(CFDictionaryGetValue(d, CFSTR(kIOPSTimeToEmptyKey)), kCFNumberIntType, &tte);
    CFNumberGetValue(CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey)), kCFNumberIntType, &cap);
    printf("IOPS: Time to Empty=%d min, Current Capacity=%d%%\n", tte, cap);
    return 0;
}
