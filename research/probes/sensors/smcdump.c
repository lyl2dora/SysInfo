// smcdump.c - READ-ONLY AppleSMC enumerator for Apple Silicon.
// Only uses selectors kSMCReadKey(5), kSMCGetKeyFromIndex(8), kSMCGetKeyInfo(9). Never writes (6).
// Build: xcrun clang -O2 -framework IOKit -framework CoreFoundation smcdump.c -o smcdump
// Usage: ./smcdump dump            -> every key: idx key type size attr rawhex decoded
//        ./smcdump keys K1 K2 ...  -> read listed keys
//        ./smcdump sample N ms K.. -> read listed keys N times every ms
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <mach/mach_error.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } keyinfo_t;
typedef struct {
    uint32_t key; vers_t vers; plimit_t pLimitData; keyinfo_t keyInfo;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SMCKeyData_t;

enum { kSMCUserClientOpen = 0, kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static io_connect_t conn;

static uint32_t fcc(const char *s) { return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3]; }
static void fcc2s(uint32_t v, char *o) { o[0] = v >> 24; o[1] = v >> 16; o[2] = v >> 8; o[3] = v; o[4] = 0; }

static kern_return_t call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t osz = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(SMCKeyData_t), out, &osz);
}

static int keyinfo(uint32_t key, keyinfo_t *ki, uint8_t *smcres) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.data8 = kSMCGetKeyInfo;
    kern_return_t kr = call(&in, &out);
    if (smcres) *smcres = out.result;
    if (kr != KERN_SUCCESS) return (int)kr;
    if (out.result != 0) return 1000 + out.result;
    *ki = out.keyInfo;
    return 0;
}

static int readkey(uint32_t key, keyinfo_t *ki, uint8_t *bytes) {
    int r = keyinfo(key, ki, NULL);
    if (r) return r;
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.keyInfo.dataSize = ki->dataSize; in.data8 = kSMCReadKey;
    kern_return_t kr = call(&in, &out);
    if (kr != KERN_SUCCESS) return (int)kr;
    if (out.result != 0) return 1000 + out.result;
    memcpy(bytes, out.bytes, 32);
    return 0;
}

static int keyat(uint32_t idx, uint32_t *key) {
    SMCKeyData_t in = {0}, out = {0};
    in.data8 = kSMCGetKeyFromIndex; in.data32 = idx;
    kern_return_t kr = call(&in, &out);
    if (kr != KERN_SUCCESS) return (int)kr;
    if (out.result != 0) return 1000 + out.result;
    *key = out.key;
    return 0;
}

// decode according to SMC type. Apple Silicon: flt/ioft little-endian; ui/si: see note printed.
static void decode(const char *type, uint32_t size, const uint8_t *b, char *o, size_t on) {
    o[0] = 0;
    if (!strcmp(type, "flt ") && size == 4) { float f; memcpy(&f, b, 4); snprintf(o, on, "%g", f); return; }
    if (!strcmp(type, "ioft") && size == 8) { uint64_t v; memcpy(&v, b, 8); snprintf(o, on, "%g", (double)v / 65536.0); return; }
    if (!strcmp(type, "ui8 ") || !strcmp(type, "flag") || (!strcmp(type, "hex_") && size == 1)) { snprintf(o, on, "%u", b[0]); return; }
    if (!strcmp(type, "si8 ")) { snprintf(o, on, "%d", (int8_t)b[0]); return; }
    if (!strcmp(type, "ui16")) { snprintf(o, on, "BE=%u LE=%u", (b[0] << 8) | b[1], (b[1] << 8) | b[0]); return; }
    if (!strcmp(type, "si16")) { snprintf(o, on, "BE=%d LE=%d", (int16_t)((b[0] << 8) | b[1]), (int16_t)((b[1] << 8) | b[0])); return; }
    if (!strcmp(type, "ui32")) { uint32_t be = ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; uint32_t le; memcpy(&le, b, 4); snprintf(o, on, "BE=%u LE=%u", be, le); return; }
    if (!strcmp(type, "si32")) { int32_t be = (int32_t)(((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]); int32_t le; memcpy(&le, b, 4); snprintf(o, on, "BE=%d LE=%d", be, le); return; }
    if (!strcmp(type, "ui64")) { uint64_t le; memcpy(&le, b, 8); snprintf(o, on, "LE=%llu", le); return; }
    if (!strcmp(type, "si64")) { int64_t le; memcpy(&le, b, 8); snprintf(o, on, "LE=%lld", le); return; }
    if (type[0] == 's' && type[1] == 'p' && size == 2) { // spXY: signed, Y fractional bits (hex digit)
        int frac = (type[3] >= 'a') ? type[3] - 'a' + 10 : type[3] - '0';
        int16_t be = (int16_t)((b[0] << 8) | b[1]);
        snprintf(o, on, "%g", be / (double)(1 << frac)); return;
    }
    if (type[0] == 'f' && type[1] == 'p' && size == 2) { // fpXY unsigned
        int frac = (type[3] >= 'a') ? type[3] - 'a' + 10 : type[3] - '0';
        uint16_t be = (uint16_t)((b[0] << 8) | b[1]);
        snprintf(o, on, "%g", be / (double)(1 << frac)); return;
    }
    if (!strncmp(type, "ch8", 3)) { size_t n = size < on - 1 ? size : on - 1; for (size_t i = 0; i < n; i++) o[i] = (b[i] >= 32 && b[i] < 127) ? b[i] : '.'; o[n] = 0; return; }
}

static void printkey(uint32_t idx, uint32_t key, int withidx) {
    char ks[5]; fcc2s(key, ks);
    keyinfo_t ki; uint8_t bytes[32] = {0};
    int r = readkey(key, &ki, bytes);
    char ts[5]; fcc2s(ki.dataType, ts);
    if (withidx) printf("%5u ", idx);
    if (r) {
        keyinfo_t ki2; int r2 = keyinfo(key, &ki2, NULL);
        if (!r2) { fcc2s(ki2.dataType, ts); printf("%s %s %2u 0x%02x READ_ERR(%d)\n", ks, ts, ki2.dataSize, ki2.dataAttributes, r); }
        else printf("%s ---- -- ---- INFO_ERR(%d)\n", ks, r2);
        return;
    }
    char hex[100] = {0}; size_t n = ki.dataSize > 32 ? 32 : ki.dataSize;
    for (size_t i = 0; i < n; i++) sprintf(hex + i * 2, "%02x", bytes[i]);
    char dec[128]; decode(ts, ki.dataSize, bytes, dec, sizeof dec);
    printf("%s %s %2u 0x%02x %-18s %s\n", ks, ts, ki.dataSize, ki.dataAttributes, hex, dec);
}

int main(int argc, char **argv) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr, "AppleSMC service not found\n"); return 1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "IOServiceOpen failed 0x%x %s\n", kr, mach_error_string(kr)); return 1; }
    fprintf(stderr, "sizeof(SMCKeyData_t)=%zu uid=%d\n", sizeof(SMCKeyData_t), getuid());

    if (argc >= 2 && !strcmp(argv[1], "dump")) {
        keyinfo_t ki; uint8_t b[32];
        int r = readkey(fcc("#KEY"), &ki, b);
        if (r) { fprintf(stderr, "#KEY read err %d\n", r); return 1; }
        uint32_t n = ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
        printf("# #KEY = %u (raw %02x%02x%02x%02x)\n# idx key  type sz attr rawhex decoded\n", n, b[0], b[1], b[2], b[3]);
        uint32_t ok = 0, fail = 0;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t key;
            if (keyat(i, &key)) { fail++; printf("%5u <index err>\n", i); continue; }
            ok++;
            printkey(i, key, 1);
        }
        // Stats iterates 0...n inclusive: check index n
        uint32_t key; int rr = keyat(n, &key);
        printf("# enumerated ok=%u fail=%u; index n (%u) -> %s\n", ok, fail, n, rr ? "error (as expected)" : "returned a key");
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "keys")) {
        for (int i = 2; i < argc; i++) { if (strlen(argv[i]) != 4) continue; printkey(0, fcc(argv[i]), 0); }
        return 0;
    }
    if (argc >= 5 && !strcmp(argv[1], "sample")) {
        int N = atoi(argv[2]); int ms = atoi(argv[3]);
        for (int s = 0; s < N; s++) {
            printf("--- sample %d\n", s);
            for (int i = 4; i < argc; i++) { if (strlen(argv[i]) != 4) continue; printkey(0, fcc(argv[i]), 0); }
            fflush(stdout);
            if (s < N - 1) usleep(ms * 1000);
        }
        return 0;
    }
    fprintf(stderr, "usage: smcdump dump | keys K.. | sample N ms K..\n");
    return 2;
}
