// smc_power.c — READ-ONLY SMC probe for the keys Stats' Battery reader uses (PPBR, PDTR, TB1T, TB2T)
// plus power/battery-family keys. Only selectors 5 (read bytes), 8 (read index) and 9 (key info) are used.
// Never writes.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct {
    UInt32 key; vers_t vers; plimit_t pLimitData; keyinfo_t keyInfo;
    char result, status, data8; UInt32 data32; unsigned char bytes[32];
} SMCKeyData_t;

static io_connect_t conn;
static UInt32 k2u(const char *s) { return (UInt32)s[0] << 24 | (UInt32)s[1] << 16 | (UInt32)s[2] << 8 | (UInt32)s[3]; }
static void u2k(UInt32 u, char *s) { s[0] = u >> 24; s[1] = u >> 16; s[2] = u >> 8; s[3] = u; s[4] = 0; }

static kern_return_t call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t osz = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCKeyData_t), out, &osz);
}
static int readkey(UInt32 key, char *type, UInt32 *size, unsigned char *bytes) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.data8 = 9;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *size = out.keyInfo.dataSize; u2k(out.keyInfo.dataType, type);
    memset(&in, 0, sizeof in); in.key = key; in.keyInfo.dataSize = *size; in.data8 = 5;
    memset(&out, 0, sizeof out);
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -2;
    memcpy(bytes, out.bytes, 32);
    return 0;
}
static int decode(const char *type, UInt32 size, unsigned char *b, double *v) {
    if (!strcmp(type, "flt ") && size == 4) { float f; memcpy(&f, b, 4); *v = f; return 1; }
    if (!strcmp(type, "ui8 ")) { *v = b[0]; return 1; }
    if (!strcmp(type, "ui16")) { *v = (b[0] << 8) | b[1]; return 1; }
    if (!strcmp(type, "ui32")) { *v = ((UInt32)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; return 1; }
    if (!strcmp(type, "si8 ")) { *v = (signed char)b[0]; return 1; }
    if (!strcmp(type, "si16")) { *v = (SInt16)((b[0] << 8) | b[1]); return 1; }
    if (!strcmp(type, "sp78")) { *v = (SInt16)((b[0] << 8) | b[1]) / 256.0; return 1; }
    if (!strcmp(type, "fpe2")) { *v = ((b[0] << 8) | b[1]) / 4.0; return 1; }
    if (!strcmp(type, "flag")) { *v = b[0]; return 1; }
    return 0;
}
static void show(const char *k) {
    char type[5]; UInt32 size; unsigned char b[32]; double v;
    int r = readkey(k2u(k), type, &size, b);
    if (r) { printf("  %s: not found (%d)\n", k, r); return; }
    if (decode(type, size, b, &v)) printf("  %s [%s,%u] = %.4f\n", k, type, size, v);
    else { printf("  %s [%s,%u] = raw", k, type, size); for (UInt32 i = 0; i < size && i < 32; i++) printf(" %02x", b[i]); printf("\n"); }
}

int main(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) { printf("AppleSMC not found\n"); return 1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr) { printf("IOServiceOpen AppleSMC failed 0x%x\n", kr); return 1; }

    printf("== Keys Stats Battery reader uses (readers.swift:119-120, 181)\n");
    const char *stats_keys[] = {"PPBR", "PDTR", "TB1T", "TB2T", "TB0T", "PSTR", NULL};
    for (int i = 0; stats_keys[i]; i++) show(stats_keys[i]);

    // enumerate all keys, print those in power/battery/adapter families
    char type[5]; UInt32 size; unsigned char b[32];
    if (readkey(k2u("#KEY"), type, &size, b) != 0) { printf("#KEY read failed\n"); return 1; }
    UInt32 n = ((UInt32)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    printf("== total SMC keys: %u\n== power/battery-family keys (P*, B*, TB*, AC*, CH*, D*R, UPS-ish) with values:\n", n);
    int shown = 0;
    for (UInt32 i = 0; i < n; i++) {
        SMCKeyData_t in = {0}, out = {0};
        in.data8 = 8; in.data32 = i;
        if (call(&in, &out) != KERN_SUCCESS || out.result != 0) continue;
        char k[5]; u2k(out.key, k);
        int interesting = (k[0] == 'P' && (k[1] == 'P' || k[1] == 'D' || k[1] == 'S' || k[1] == 'H' || k[1] == 'A' || k[1] == 'M')) ||
                          (k[0] == 'B') || (k[0] == 'T' && k[1] == 'B') || (k[0] == 'A' && k[1] == 'C') ||
                          (k[0] == 'C' && k[1] == 'H') || (k[0] == 'V' && (k[1] == 'D' || k[1] == 'P' || k[1] == 'B')) ||
                          (k[0] == 'I' && (k[1] == 'D' || k[1] == 'P' || k[1] == 'B'));
        if (interesting) { show(k); shown++; }
    }
    printf("== shown %d keys\n", shown);
    printf("== second sample of PSTR/PDTR/PPBR after 3s\n");
    sleep(3);
    show("PSTR"); show("PDTR"); show("PPBR");
    IOServiceClose(conn);
    return 0;
}
