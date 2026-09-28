// NVMe SMART probe using the PUBLIC SDK header IOKit/storage/nvme/NVMeSMARTLibExternal.h
// Read-only: SMARTReadData, GetIdentifyData, GetLogPage. No admin/set-feature commands.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/IOBlockStorageDevice.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

static double ms_since(uint64_t t0) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
}
static void cfstr(CFTypeRef v, char *buf, size_t n) {
    buf[0] = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, buf, n, kCFStringEncodingUTF8);
}
static void trimcopy(char *dst, const uint8_t *src, int n) {
    memcpy(dst, src, n); dst[n] = 0;
    for (int i = n - 1; i >= 0 && (dst[i] == ' ' || dst[i] == 0); i--) dst[i] = 0;
}
static long double u128(const uint64_t v[2]) { return (long double)v[0] + (long double)v[1] * 18446744073709551616.0L; }

int main(void) {
    printf("sizeof(NVMeSMARTData)=%zu sizeof(NVMeIdentifyControllerStruct)=%zu sizeof(IONVMeSMARTInterface)=%zu uid=%d\n",
           sizeof(NVMeSMARTData), sizeof(NVMeIdentifyControllerStruct), sizeof(IONVMeSMARTInterface), getuid());
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDeviceClass), &it) != KERN_SUCCESS) return 1;
    io_object_t dev;
    while ((dev = IOIteratorNext(it))) {
        io_name_t cls; IOObjectGetClass(dev, cls);
        CFTypeRef cap = IORegistryEntryCreateCFProperty(dev, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFAllocatorDefault, 0);
        CFDictionaryRef dc = IORegistryEntryCreateCFProperty(dev, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
        char model[128] = "", serial[128] = "";
        if (dc) { cfstr(CFDictionaryGetValue(dc, CFSTR("Product Name")), model, sizeof model); cfstr(CFDictionaryGetValue(dc, CFSTR("Serial Number")), serial, sizeof serial); CFRelease(dc); }
        int capable = cap && CFGetTypeID(cap) == CFBooleanGetTypeID() && CFBooleanGetValue(cap);
        if (cap) CFRelease(cap);
        printf("\n== %s  model=%s serial=%s NVMeSMARTCapable=%d\n", cls, model, serial, capable);
        if (!capable) { IOObjectRelease(dev); continue; }

        IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
        uint64_t t0 = mach_absolute_time();
        kern_return_t kr = IOCreatePlugInInterfaceForService(dev, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        printf("  IOCreatePlugInInterfaceForService kr=0x%x (%.1f ms)\n", kr, ms_since(t0));
        if (kr != KERN_SUCCESS || !plugin) { IOObjectRelease(dev); continue; }
        IONVMeSMARTInterface **smart = NULL;
        HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
        printf("  QueryInterface hr=0x%x version=%u revision=%u\n", (unsigned)hr, smart ? (*smart)->version : 0, smart ? (*smart)->revision : 0);
        if (hr == S_OK && smart) {
            NVMeSMARTData d; memset(&d, 0, sizeof d);
            t0 = mach_absolute_time();
            IOReturn r = (*smart)->SMARTReadData(smart, &d);
            printf("  SMARTReadData r=0x%x (%.1f ms)\n", r, ms_since(t0));
            if (r == kIOReturnSuccess) {
                printf("    critical_warning=0x%02x temperature=%uK (%dC) avail_spare=%u%% spare_thresh=%u%% percentage_used=%u%%\n",
                       d.CRITICAL_WARNING, d.TEMPERATURE, (int)d.TEMPERATURE - 273, d.AVAILABLE_SPARE, d.AVAILABLE_SPARE_THRESHOLD, d.PERCENTAGE_USED);
                printf("    data_units_read=%.0Lf (%.3Lf TB) data_units_written=%.0Lf (%.3Lf TB)\n",
                       u128(d.DATA_UNITS_READ), u128(d.DATA_UNITS_READ) * 512000.0L / 1e12L, u128(d.DATA_UNITS_WRITTEN), u128(d.DATA_UNITS_WRITTEN) * 512000.0L / 1e12L);
                printf("    host_read_cmds=%.0Lf host_write_cmds=%.0Lf ctrl_busy_min=%.0Lf power_cycles=%.0Lf power_on_hours=%.0Lf unsafe_shutdowns=%.0Lf media_errors=%.0Lf err_log_entries=%.0Lf\n",
                       u128(d.HOST_READ_COMMANDS), u128(d.HOST_WRITE_COMMANDS), u128(d.CONTROLLER_BUSY_TIME), u128(d.POWER_CYCLES), u128(d.POWER_ON_HOURS), u128(d.UNSAFE_SHUTDOWNS), u128(d.MEDIA_ERRORS), u128(d.NUM_ERROR_INFO_LOG_ENTRIES));
                // bytes 192..: warning temp time, critical temp time, temp sensors 1..8 (NVMe 1.2+), thermal mgmt counters
                const uint8_t *b = (const uint8_t *)&d;
                uint32_t wtt, cct; memcpy(&wtt, b + 192, 4); memcpy(&cct, b + 196, 4);
                printf("    warn_temp_time_min=%u crit_temp_time_min=%u temp_sensors:", wtt, cct);
                for (int i = 0; i < 8; i++) { uint16_t ts; memcpy(&ts, b + 200 + 2 * i, 2); if (ts) printf(" TS%d=%dC", i + 1, (int)ts - 273); }
                uint32_t tmt[4]; memcpy(tmt, b + 216, 16);
                printf("  TMT1count=%u TMT2count=%u TMT1time=%us TMT2time=%us\n", tmt[0], tmt[1], tmt[2], tmt[3]);
            }
            // Identify controller (ns 0)
            static NVMeIdentifyControllerStruct idc; memset(&idc, 0, sizeof idc);
            t0 = mach_absolute_time();
            r = (*smart)->GetIdentifyData(smart, &idc, 0);
            printf("  GetIdentifyData(ctrl) r=0x%x (%.1f ms)", r, ms_since(t0));
            if (r == kIOReturnSuccess) {
                char sn[32], mn[64], fr[16];
                trimcopy(sn, idc.SERIAL_NUMBER, 20); trimcopy(mn, idc.MODEL_NUMBER, 40); trimcopy(fr, idc.FW_REVISION, 8);
                printf(" VID=0x%04x SSVID=0x%04x MN='%s' SN='%s' FR='%s' NN=%u LPA=0x%x\n", idc.PCI_VID, idc.PCI_SSVID, mn, sn, fr, idc.NUM_OF_NAMESPACES, idc.LOG_PAGE_ATTR);
                // WCTEMP / CCTEMP live at bytes 266/268 of identify controller
                const uint8_t *ib = (const uint8_t *)&idc; uint16_t wct, cct2; memcpy(&wct, ib + 266, 2); memcpy(&cct2, ib + 268, 2);
                printf("    WCTEMP=%dC CCTEMP=%dC\n", wct ? (int)wct - 273 : 0, cct2 ? (int)cct2 - 273 : 0);
            } else printf("\n");
            // Identify namespace 1
            static NVMeIdentifyNamespaceStruct ns; memset(&ns, 0, sizeof ns);
            r = (*smart)->GetIdentifyData(smart, &ns, 1);
            printf("  GetIdentifyData(ns1) r=0x%x", r);
            if (r == kIOReturnSuccess) {
                int lbaf = ns.FORMATTED_LBA_SIZE & 0xF; int lbads = ns.LBA_FORMATS[lbaf].LBA_DATA_SIZE;
                printf(" NSZE=%llu NCAP=%llu NUSE=%llu lbads=2^%d -> used %.1f GB of %.1f GB\n", ns.NAMESPACE_SIZE, ns.NAMESPACE_CAPACITY, ns.NAMESPACE_UTILIZATION, lbads,
                       (double)ns.NAMESPACE_UTILIZATION * (1ull << lbads) / 1e9, (double)ns.NAMESPACE_SIZE * (1ull << lbads) / 1e9);
            } else printf("\n");
            // Log page 0x02 (SMART) via GetLogPage, 128 dwords -> numDWords is zero-based
            static uint8_t lp[4096]; memset(lp, 0, sizeof lp);
            r = (*smart)->GetLogPage(smart, lp, 0x02, 127);
            printf("  GetLogPage(0x02,127) r=0x%x", r);
            if (r == kIOReturnSuccess) { uint16_t t; memcpy(&t, lp + 1, 2); printf(" temp=%dC pct_used=%u\n", (int)t - 273, lp[5]); } else printf("\n");
            // Log page 0x01 error info (first 64 bytes)
            memset(lp, 0, sizeof lp);
            r = (*smart)->GetLogPage(smart, lp, 0x01, 15);
            printf("  GetLogPage(0x01 error,15) r=0x%x\n", r);
            // Log page 0x03 firmware slot
            memset(lp, 0, sizeof lp);
            r = (*smart)->GetLogPage(smart, lp, 0x03, 127);
            printf("  GetLogPage(0x03 fw slot,127) r=0x%x", r);
            if (r == kIOReturnSuccess) { char fs[9]; memcpy(fs, lp + 8, 8); fs[8] = 0; printf(" afi=0x%02x slot1='%s'\n", lp[0], fs); } else printf("\n");
            (*smart)->Release(smart);
        }
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(dev);
    }
    IOObjectRelease(it);
    return 0;
}
