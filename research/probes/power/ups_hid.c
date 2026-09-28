// ups_hid.c — READ-ONLY: open the USB HID UPS non-exclusively and read Power Device (0x84) /
// Battery System (0x85) input & feature element values (GET_REPORT only; never SET_REPORT / output).
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <stdio.h>

static const char *name84(uint32_t u) {
    switch (u) {
    case 0x02: return "PresentStatus"; case 0x04: return "UPS"; case 0x12: return "Battery"; case 0x16: return "PowerConverter";
    case 0x1a: return "Input"; case 0x1c: return "Output"; case 0x24: return "PowerSummary"; case 0x30: return "Voltage";
    case 0x31: return "Current"; case 0x32: return "Frequency"; case 0x33: return "ApparentPower"; case 0x34: return "ActivePower";
    case 0x35: return "PercentLoad"; case 0x36: return "Temperature"; case 0x40: return "ConfigVoltage"; case 0x42: return "ConfigFrequency";
    case 0x43: return "ConfigApparentPower"; case 0x44: return "ConfigActivePower"; case 0x45: return "ConfigPercentLoad";
    case 0x53: return "LowVoltageTransfer"; case 0x54: return "HighVoltageTransfer"; case 0x56: return "DelayBeforeStartup";
    case 0x57: return "DelayBeforeShutdown"; case 0x58: return "Test"; case 0x5a: return "AudibleAlarmControl"; case 0x61: return "Good";
    case 0x62: return "InternalFailure"; case 0x65: return "Overload"; case 0x69: return "ShutdownImminent"; case 0x6b: return "SwitchOn/Off";
    case 0x6c: return "Switchable"; case 0x6e: return "Boost"; case 0x6f: return "Buck"; case 0x73: return "CommunicationLost";
    case 0xfd: return "iManufacturer"; case 0xfe: return "iProduct"; case 0xff: return "iSerialNumber";
    } return "?";
}
static const char *name85(uint32_t u) {
    switch (u) {
    case 0x29: return "RemainingCapacityLimit"; case 0x2a: return "RemainingTimeLimit"; case 0x2c: return "CapacityMode";
    case 0x42: return "BelowRemainingCapacityLimit"; case 0x43: return "RemainingTimeLimitExpired"; case 0x44: return "Charging";
    case 0x45: return "Discharging"; case 0x4b: return "NeedReplacement"; case 0x66: return "RemainingCapacity";
    case 0x67: return "FullChargeCapacity"; case 0x68: return "RunTimeToEmpty"; case 0x83: return "DesignCapacity";
    case 0x85: return "ManufacturerDate"; case 0x89: return "iDeviceChemistry"; case 0x8b: return "Rechargeable";
    case 0x8c: return "WarningCapacityLimit"; case 0x8d: return "CapacityGranularity1"; case 0x8e: return "CapacityGranularity2";
    case 0x8f: return "iOEMInformation"; case 0xd0: return "ACPresent"; case 0xd1: return "BatteryPresent"; case 0xdb: return "VoltageNotRegulated";
    } return "?";
}

int main(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int page = 0x84;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    const void *k[] = {CFSTR(kIOHIDPrimaryUsagePageKey)}; const void *v[] = {p};
    CFDictionaryRef match = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOReturn r = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    printf("IOHIDManagerOpen(PrimaryUsagePage=0x84) = 0x%x\n", r);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    if (!set) { printf("no UPS HID devices\n"); return 0; }
    CFIndex n = CFSetGetCount(set);
    IOHIDDeviceRef devs[8]; CFSetGetValues(set, (const void **)devs);
    for (CFIndex d = 0; d < n && d < 8; d++) {
        IOHIDDeviceRef dev = devs[d];
        char prod[256] = "";
        CFStringRef ps = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey));
        if (ps) CFStringGetCString(ps, prod, sizeof prod, kCFStringEncodingUTF8);
        printf("== device: %s\n", prod);
        CFArrayRef els = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
        CFIndex ne = els ? CFArrayGetCount(els) : 0;
        printf("elements: %ld\n", ne);
        int ok = 0, fail = 0;
        for (CFIndex i = 0; i < ne; i++) {
            IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(els, i);
            IOHIDElementType t = IOHIDElementGetType(el);
            uint32_t up = IOHIDElementGetUsagePage(el), u = IOHIDElementGetUsage(el);
            if (t == kIOHIDElementTypeCollection || t == kIOHIDElementTypeOutput) continue;
            if (up != 0x84 && up != 0x85) continue;
            IOHIDElementRef par = IOHIDElementGetParent(el);
            uint32_t pu = par ? IOHIDElementGetUsage(par) : 0, pup = par ? IOHIDElementGetUsagePage(par) : 0;
            IOHIDValueRef val = NULL;
            IOReturn gr = IOHIDDeviceGetValue(dev, el, &val);
            const char *tn = t == kIOHIDElementTypeFeature ? "feature" : "input";
            int32_t ue = IOHIDElementGetUnitExponent(el); uint32_t unit = IOHIDElementGetUnit(el);
            if (gr == kIOReturnSuccess && val) {
                ok++;
                printf("  [%s] %s(0x%02x:0x%02x).%s(0x%02x:0x%02x) rid=%u = %ld  (unit=0x%x exp=%d)\n", tn,
                       pup == 0x84 ? name84(pu) : (pup == 0x85 ? name85(pu) : "?"), pup, pu,
                       up == 0x84 ? name84(u) : name85(u), up, u, IOHIDElementGetReportID(el),
                       IOHIDValueGetIntegerValue(val), unit, ue);
            } else {
                fail++;
                printf("  [%s] %s(0x%02x) rid=%u -> GetValue err 0x%x\n", tn, up == 0x84 ? name84(u) : name85(u), u, IOHIDElementGetReportID(el), gr);
            }
        }
        printf("read ok=%d failed=%d\n", ok, fail);
        if (els) CFRelease(els);
    }
    CFRelease(set);
    IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
    return 0;
}
