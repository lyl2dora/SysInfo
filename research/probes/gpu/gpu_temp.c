// Probe (READ-ONLY): GPU temperature via SMC keys (Stats' M5 list + enumeration of Tg* keys) and via HID temperature services.
// Only SMC read selectors are used (kSMCGetKeyInfo=9, kSMCReadKey=5, kSMCGetKeyFromIndex=8). No writes.
// build: xcrun clang -O1 -o gpu_temp gpu_temp.c -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;

static io_connect_t conn;
static uint32_t k4(const char *s) { return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3]; }
static void s4(uint32_t k, char *o) { o[0] = k >> 24; o[1] = k >> 16; o[2] = k >> 8; o[3] = k; o[4] = 0; }
static kern_return_t call(SMCParam *in, SMCParam *out) { size_t sz = sizeof(SMCParam); return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCParam), out, &sz); }
static int readKey(uint32_t key, SMCKeyInfo *info, uint8_t *bytes) {
    SMCParam in = {0}, out = {0};
    in.key = key; in.data8 = 9;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.keyInfo;
    in.keyInfo.dataSize = out.keyInfo.dataSize; in.data8 = 5;
    memset(&out, 0, sizeof out);
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -2;
    memcpy(bytes, out.bytes, 32);
    return 0;
}
static double decode(SMCKeyInfo info, uint8_t *b) {
    char t[5]; s4(info.dataType, t);
    if (!strcmp(t, "flt ")) { float f; memcpy(&f, b, 4); return f; }
    if (!strcmp(t, "sp78")) return (int16_t)(b[0] << 8 | b[1]) / 256.0;
    if (!strcmp(t, "ui8 ")) return b[0];
    if (!strcmp(t, "ui16")) return b[0] << 8 | b[1];
    return -999;
}

// HID (private) declarations
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

int main(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != KERN_SUCCESS) { printf("AppleSMC open failed\n"); }
    else {
        const char *statsKeys[] = {"Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"};
        printf("Stats m5Gen GPU keys (Modules/Sensors/values.swift:494-501):\n");
        for (int r = 0; r < 2; r++) {
            for (int i = 0; i < 8; i++) {
                SMCKeyInfo info; uint8_t b[32]; char t[5];
                int rc = readKey(k4(statsKeys[i]), &info, b);
                if (rc) printf("  %s: not readable (rc=%d)\n", statsKeys[i], rc);
                else { s4(info.dataType, t); printf("  %s [%s] = %.2f\n", statsKeys[i], t, decode(info, b)); }
            }
            if (r == 0) { printf(" (second read after 1s)\n"); sleep(1); }
        }
        // enumerate all keys, list Tg* / Tf* and GPU-power-looking keys
        SMCKeyInfo info; uint8_t b[32];
        uint32_t total = 0;
        if (!readKey(k4("#KEY"), &info, b)) total = (uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
        printf("SMC key count: %u\nTg*/PG*/Pg* keys:\n", total);
        for (uint32_t i = 0; i < total; i++) {
            SMCParam in = {0}, out = {0}; in.data8 = 8; in.data32 = i;
            if (call(&in, &out) != KERN_SUCCESS) continue;
            char name[5]; s4(out.key, name);
            if (!strncmp(name, "Tg", 2) || !strncmp(name, "PG", 2) || !strncmp(name, "Pg", 2) || !strncmp(name, "VG", 2)) {
                char t[5];
                if (!readKey(out.key, &info, b)) { s4(info.dataType, t); printf("  %s [%s] = %.3f\n", name, t, decode(info, b)); }
            }
        }
        IOServiceClose(conn);
    }
    // HID temperature sensors whose Product mentions GPU
    IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    int page = 0xff00, usage = 5;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef m = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(c, m);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(c);
    CFIndex n = services ? CFArrayGetCount(services) : 0;
    printf("HID temperature services: %ld; GPU-related:\n", (long)n);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef name = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        if (!name) continue;
        char buf[128]; CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        if (strcasestr(buf, "gpu") || strcasestr(buf, "gfx")) {
            IOHIDEventRef e = IOHIDServiceClientCopyEvent(s, 15, 0, 0);
            printf("  %s = %.2f C\n", buf, e ? IOHIDEventGetFloatValue(e, 15 << 16) : -1.0);
            if (e) CFRelease(e);
        }
        CFRelease(name);
    }
    return 0;
}
