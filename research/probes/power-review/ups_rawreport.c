// ups_rawreport.c — REVIEW probe (read-only). Independent check of the original ups_hid.c values using a
// DIFFERENT method: raw HID GET_REPORT(Feature) via IOHIDDeviceGetReport, decoding bytes by hand
// (little-endian, element order + IOHIDElementGetReportSize), then applying standard HID unit math
// (HID SI-linear units are CGS: 1 V = 1e7 base units, 1 W = 1e7 base units) instead of vendor quirks.
// Also prints IOHIDValueGetScaledValue(kIOHIDValueScaleTypeExponent) and IOPS values for the same instant.
// Never calls IOHIDDeviceSetReport / SetValue.
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <stdio.h>
#include <math.h>

static int nibble(int n) { return n >= 8 ? n - 16 : n; }
static void decode_unit(uint32_t unit, char *out) {
    // HID unit: nibbles [sys, len, mass, time, temp, current, lum]
    int sys = unit & 0xf, len = nibble((unit >> 4) & 0xf), mass = nibble((unit >> 8) & 0xf), tim = nibble((unit >> 12) & 0xf),
        cur = nibble((unit >> 20) & 0xf);
    sprintf(out, "sys=%d cm^%d g^%d s^%d A^%d", sys, len, mass, tim, cur);
}

int main(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int page = 0x84;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    const void *k[] = {CFSTR(kIOHIDPrimaryUsagePageKey)}; const void *v[] = {p};
    CFDictionaryRef match = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(mgr, match);
    printf("IOHIDManagerOpen = 0x%x\n", IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone));
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    if (!set || CFSetGetCount(set) == 0) { printf("no UPS\n"); return 0; }
    IOHIDDeviceRef dev; CFSetGetValues(set, (const void **)&dev);
    CFArrayRef els = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
    int rids[] = {12, 22, 38, 37, 48, 49, 50, 51, 80, 82, 7};
    for (unsigned r = 0; r < sizeof rids / sizeof *rids; r++) {
        int rid = rids[r];
        uint8_t buf[64] = {0}; CFIndex len = sizeof buf;
        IOReturn kr = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, rid, buf, &len);
        printf("GET_REPORT(Feature, id=%d) kr=0x%x len=%ld bytes:", rid, kr, len);
        for (CFIndex i = 0; i < len; i++) printf(" %02x", buf[i]);
        printf("\n");
        if (kr) continue;
        // walk feature elements of this report id in order, decode bit fields (byte 0 = report id)
        int bit = 8;
        for (CFIndex i = 0; i < CFArrayGetCount(els); i++) {
            IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(els, i);
            if (IOHIDElementGetType(el) != kIOHIDElementTypeFeature || (int)IOHIDElementGetReportID(el) != rid) continue;
            uint32_t sz = IOHIDElementGetReportSize(el), cnt = IOHIDElementGetReportCount(el);
            for (uint32_t c = 0; c < cnt; c++) {
                uint64_t raw = 0;
                for (uint32_t b = 0; b < sz; b++) { int bb = bit + b; if (bb / 8 < len && (buf[bb / 8] >> (bb % 8) & 1)) raw |= 1ULL << b; }
                long long sv = (long long)raw;
                if (IOHIDElementGetLogicalMin(el) < 0 && sz < 64 && (raw >> (sz - 1) & 1)) sv = (long long)raw - (1LL << sz);
                int32_t ex = IOHIDElementGetUnitExponent(el); uint32_t unit = IOHIDElementGetUnit(el);
                char us[80]; decode_unit(unit, us);
                double si = NAN;
                // voltage (cm^2 g s^-3 A^-1) and power (cm^2 g s^-3): CGS base = 1e-7 SI
                if (unit == 0xf0d121 || unit == 0xd121) si = sv * pow(10, nibble(ex) - 7);
                IOHIDValueRef val = NULL; double scaled = NAN;
                if (IOHIDDeviceGetValue(dev, el, &val) == kIOReturnSuccess && val) scaled = IOHIDValueGetScaledValue(val, kIOHIDValueScaleTypeExponent);
                printf("   usage %02x:%02x bits[%d..%d) raw=%lld  unit=0x%x (%s) exp=%d  -> SI=%s%.3f  | IOHIDValueGetScaledValue(Exponent)=%.4g\n",
                       IOHIDElementGetUsagePage(el), IOHIDElementGetUsage(el), bit, bit + sz, sv, unit, us, ex,
                       isnan(si) ? "n/a " : "", isnan(si) ? 0.0 : si, scaled);
                bit += sz;
            }
        }
    }
    // IOPS at the same moment
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
        int tte = -1, volt = -1, cap = -1;
        CFNumberRef n;
        if ((n = CFDictionaryGetValue(d, CFSTR(kIOPSTimeToEmptyKey)))) CFNumberGetValue(n, kCFNumberIntType, &tte);
        if ((n = CFDictionaryGetValue(d, CFSTR(kIOPSVoltageKey)))) CFNumberGetValue(n, kCFNumberIntType, &volt);
        if ((n = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey)))) CFNumberGetValue(n, kCFNumberIntType, &cap);
        printf("IOPS same instant: Current Capacity=%d%% Time to Empty=%d min Voltage=%d (mV?)\n", cap, tte, volt);
    }
    CFRelease(list); CFRelease(blob);
    IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
    return 0;
}
