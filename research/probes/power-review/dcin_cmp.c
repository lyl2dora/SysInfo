// dcin_cmp.c — REVIEW probe (read-only). Cross-check AppleSmartBattery.PowerTelemetryData (60 s snapshot +
// accumulators) against SMC PDTR / VD0R*ID0R / PSTR sampled at 1 Hz over the same window.
// Also tests hypotheses: SystemEnergyConsumed == SystemPowerIn/3.6 (uWh per 1 s sample),
// WallEnergyEstimate == SystemEnergyConsumed + AdapterEfficiencyLoss, and PSTR ~= wall (AC) power estimate.
// SMC selectors used: 9 (keyinfo), 5 (read). Never writes.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct { UInt32 key; vers_t vers; plimit_t pLimitData; keyinfo_t keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } SMCKeyData_t;
static io_connect_t conn;
static UInt32 k2u(const char *s) { return (UInt32)s[0] << 24 | (UInt32)s[1] << 16 | (UInt32)s[2] << 8 | (UInt32)s[3]; }
static kern_return_t call(SMCKeyData_t *in, SMCKeyData_t *out) { size_t o = sizeof *out; return IOConnectCallStructMethod(conn, 2, in, sizeof *in, out, &o); }
static double smcflt(const char *k) {
    SMCKeyData_t in = {0}, out = {0}; in.key = k2u(k); in.data8 = 9;
    if (call(&in, &out) || out.result) return -1;
    UInt32 sz = out.keyInfo.dataSize, ty = out.keyInfo.dataType;
    memset(&in, 0, sizeof in); in.key = k2u(k); in.keyInfo.dataSize = sz; in.data8 = 5; memset(&out, 0, sizeof out);
    if (call(&in, &out) || out.result) return -2;
    if (ty != k2u("flt ") || sz != 4) return -3;
    float f; memcpy(&f, out.bytes, 4); return f;
}
static io_service_t sb;
static long long tget(CFDictionaryRef d, const char *k) {
    CFStringRef s = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    CFNumberRef n = CFDictionaryGetValue(d, s); CFRelease(s);
    long long v = -1; if (n) CFNumberGetValue(n, kCFNumberLongLongType, &v); return v;
}
static long long regint(const char *k) {
    CFStringRef s = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(sb, s, NULL, 0); CFRelease(s);
    long long r = -1; if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongLongType, &r);
    if (v) CFRelease(v); return r;
}
typedef struct { long long upd, pin, vin, iin, sysE, wall, loss, accP, cntP, accE, accW, accL; } tel_t;
static tel_t tel(void) {
    tel_t t = {0}; t.upd = regint("UpdateTime");
    CFDictionaryRef d = IORegistryEntryCreateCFProperty(sb, CFSTR("PowerTelemetryData"), NULL, 0);
    if (!d) return t;
    t.pin = tget(d, "SystemPowerIn"); t.vin = tget(d, "SystemVoltageIn"); t.iin = tget(d, "SystemCurrentIn");
    t.sysE = tget(d, "SystemEnergyConsumed"); t.wall = tget(d, "WallEnergyEstimate"); t.loss = tget(d, "AdapterEfficiencyLoss");
    t.accP = tget(d, "AccumulatedSystemPowerIn"); t.cntP = tget(d, "SystemPowerInAccumulatorCount");
    t.accE = tget(d, "AccumulatedSystemEnergyConsumed"); t.accW = tget(d, "AccumulatedWallEnergyEstimate"); t.accL = tget(d, "AccumulatedAdapterEfficiencyLoss");
    CFRelease(d); return t;
}
int main(int argc, char **argv) {
    int dur = argc > 1 ? atoi(argv[1]) : 190;
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (IOServiceOpen(s, mach_task_self(), 0, &conn)) { printf("SMC open failed\n"); return 1; }
    sb = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    tel_t prev = tel();
    printf("start: wall-clock=%ld UpdateTime=%lld (age %lds)\n", time(NULL), prev.upd, time(NULL) - (long)prev.upd);
    double sumP = 0, sumVI = 0, sumS = 0; int n = 0; double lastP = 0;
    for (int i = 0; i < dur; i++) {
        double p = smcflt("PDTR"), v = smcflt("VD0R"), a = smcflt("ID0R"), st = smcflt("PSTR");
        sumP += p; sumVI += v * a; sumS += st; n++; lastP = p;
        if (i % 10 == 0) printf("  t=%3d PDTR=%.3f W  VD0R*ID0R=%.3f W (V=%.3f)  PSTR=%.3f W  PSTR/PDTR=%.3f\n", i, p, v * a, v, st, p > 0 ? st / p : 0);
        tel_t cur = tel();
        if (cur.upd != prev.upd) {
            long long dc = cur.cntP - prev.cntP;
            double accAvg = dc > 0 ? (double)(cur.accP - prev.accP) / dc : -1;
            printf("== telemetry update UpdateTime %lld -> %lld (+%llds), accumulator count +%lld\n", prev.upd, cur.upd, cur.upd - prev.upd, dc);
            printf("   SMC PDTR mean over my %d samples since last update = %.0f mW | VD0R*ID0R mean = %.0f mW | PSTR mean = %.0f mW\n", n, sumP / n * 1000, sumVI / n * 1000, sumS / n * 1000);
            printf("   Telemetry avg (dAccSysPowerIn/dCount) = %.0f mW | snapshot SystemPowerIn = %lld mW (SMC PDTR just now %.0f mW) | V=%lld mV I=%lld mA\n", accAvg, cur.pin, lastP * 1000, cur.vin, cur.iin);
            printf("   units: SystemEnergyConsumed=%lld vs SystemPowerIn/3.6=%.1f | Wall=%lld vs SysE+Loss=%lld | Wall*3.6=%.0f mW (est. AC wall power) | Wall/SysE=%.3f\n",
                   cur.sysE, cur.pin / 3.6, cur.wall, cur.sysE + cur.loss, cur.wall * 3.6, cur.sysE > 0 ? (double)cur.wall / cur.sysE : 0);
            printf("   accum over window: dAccSysE*3.6/dCount=%.0f mW  dAccWall*3.6/dCount=%.0f mW  -> implied avg wall/DC ratio %.3f vs my PSTR/PDTR mean ratio %.3f\n",
                   dc > 0 ? (cur.accE - prev.accE) * 3.6 / dc : -1, dc > 0 ? (cur.accW - prev.accW) * 3.6 / dc : -1,
                   (cur.accE - prev.accE) > 0 ? (double)(cur.accW - prev.accW) / (cur.accE - prev.accE) : 0, sumP > 0 ? sumS / sumP : 0);
            if (prev.upd > 0 && n >= 50) printf("   => DIFF SMC-mean vs telemetry-avg = %+.1f%%\n", (sumP / n * 1000 - accAvg) / accAvg * 100);
            prev = cur; sumP = sumVI = sumS = 0; n = 0;
        }
        sleep(1);
    }
    IOServiceClose(conn);
    return 0;
}
