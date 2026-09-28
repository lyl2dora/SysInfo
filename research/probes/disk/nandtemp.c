// Disk (NAND) temperature: (1) HID AppleEmbeddedNVMeTemperatureSensor via private IOHIDEventSystemClient,
// (2) SMC TH* keys, READ-ONLY (enumerate by index, read value). Never writes SMC.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
#define kIOHIDEventTypeTemperature 15

static void hid(int round) {
    int page = 0xff00, usage = 5;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef m = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    IOHIDEventSystemClientSetMatching(c, m);
    CFArrayRef s = IOHIDEventSystemClientCopyServices(c);
    long n = s ? CFArrayGetCount(s) : 0;
    printf("HID round %d: %ld temperature services (page 0xff00 usage 5)\n", round, n);
    for (long i = 0; i < n; i++) {
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(s, i);
        CFStringRef name = IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
        char buf[128] = "?"; if (name) CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        if (strstr(buf, "NAND") || strstr(buf, "SSD") || strstr(buf, "NVMe") || strstr(buf, "ANS")) {
            IOHIDEventRef e = IOHIDServiceClientCopyEvent(sc, kIOHIDEventTypeTemperature, 0, 0);
            printf("  '%s' = %.2f C\n", buf, e ? IOHIDEventGetFloatValue(e, kIOHIDEventTypeTemperature << 16) : -1);
            if (e) CFRelease(e);
        }
        if (name) CFRelease(name);
    }
    if (s) CFRelease(s);
    CFRelease(c); CFRelease(m); CFRelease(p); CFRelease(u);
}

// --- SMC read-only ---
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct { UInt32 key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } SMCKeyData;
static io_connect_t conn;
static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t os = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCKeyData), out, &os);
}
static UInt32 k2u(const char *s) { return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3]; }
static void u2k(UInt32 u, char *s) { s[0] = u >> 24; s[1] = u >> 16; s[2] = u >> 8; s[3] = u; s[4] = 0; }
static int smc_read(UInt32 key, SMCKeyInfo *ki, unsigned char *bytes) {
    SMCKeyData in = {0}, out = {0};
    in.key = key; in.data8 = 9; // kSMCGetKeyInfo
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result) return -1;
    *ki = out.keyInfo;
    memset(&in, 0, sizeof in); in.key = key; in.keyInfo.dataSize = ki->dataSize; in.data8 = 5; // kSMCReadKey
    memset(&out, 0, sizeof out);
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result) return -2;
    memcpy(bytes, out.bytes, 32);
    return 0;
}
static void smc(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != KERN_SUCCESS) { printf("SMC open failed\n"); return; }
    SMCKeyInfo ki; unsigned char b[32];
    if (smc_read(k2u("#KEY"), &ki, b) != 0) { printf("#KEY read failed\n"); return; }
    UInt32 count = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    printf("SMC #KEY=%u; TH* (storage/NAND) keys:\n", count);
    for (UInt32 i = 0; i < count; i++) {
        SMCKeyData in = {0}, out = {0}; in.data8 = 8; in.data32 = i; // kSMCGetKeyFromIndex
        if (smc_call(&in, &out) != KERN_SUCCESS || out.result) continue;
        char name[5]; u2k(out.key, name);
        if (name[0] != 'T' || name[1] != 'H') continue;
        if (smc_read(out.key, &ki, b) != 0) { printf("  %s read failed\n", name); continue; }
        char type[5]; u2k(ki.dataType, type);
        if (!strcmp(type, "flt ") && ki.dataSize == 4) { float f; memcpy(&f, b, 4); printf("  %s [%s,%u] = %.2f\n", name, type, ki.dataSize, f); }
        else { printf("  %s [%s,%u] = ", name, type, ki.dataSize); for (UInt32 j = 0; j < ki.dataSize && j < 8; j++) printf("%02x", b[j]); printf("\n"); }
    }
    IOServiceClose(conn);
}

int main(void) { hid(1); sleep(2); hid(2); smc(); return 0; }
