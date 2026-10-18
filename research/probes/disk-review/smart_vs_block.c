// Review probe: compare NVMe SMART data_units_written/read (512,000-byte units) on the internal SSD against
// IOBlockStorageDriver Statistics of the same device over the same window, around our own 256 MiB write + read.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/IOBlockStorageDevice.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
typedef struct { unsigned long long ur, uw, br, bw, opsw, opsr; int tempK; unsigned poh; } snap_t;
static long long num(CFDictionaryRef d, const char *k) { CFStringRef ks = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8); CFNumberRef n = CFDictionaryGetValue(d, ks); CFRelease(ks); long long v = -1; if (n) CFNumberGetValue(n, kCFNumberLongLongType, &v); return v; }
static int take(snap_t *s) {
    io_service_t dev = 0; io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEmbeddedNVMeBlockDevice"), &it);
    dev = IOIteratorNext(it); IOObjectRelease(it);
    if (!dev) return -1;
    io_registry_entry_t drv; IORegistryEntryGetChildEntry(dev, kIOServicePlane, &drv);
    CFDictionaryRef st = IORegistryEntryCreateCFProperty(drv, CFSTR("Statistics"), NULL, 0);
    s->br = num(st, "Bytes (Read)"); s->bw = num(st, "Bytes (Write)"); s->opsr = num(st, "Operations (Read)"); s->opsw = num(st, "Operations (Write)");
    CFRelease(st); IOObjectRelease(drv);
    IOCFPlugInInterface **pl = NULL; SInt32 sc; IONVMeSMARTInterface **sm = NULL;
    if (IOCreatePlugInInterfaceForService(dev, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pl, &sc) != 0) return -2;
    (*pl)->QueryInterface(pl, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&sm);
    NVMeSMARTData d; memset(&d, 0, sizeof d);
    IOReturn r = (*sm)->SMARTReadData(sm, &d);
    s->ur = d.DATA_UNITS_READ[0]; s->uw = d.DATA_UNITS_WRITTEN[0]; s->tempK = d.TEMPERATURE; s->poh = (unsigned)d.POWER_ON_HOURS[0];
    (*sm)->Release(sm); IODestroyPlugInInterface(pl); IOObjectRelease(dev);
    return r;
}
int main(int argc, char **argv) {
    snap_t a, b; take(&a);
    printf("before: SMART units r=%llu w=%llu temp=%dK poh=%u | block bytes r=%llu w=%llu\n", a.ur, a.uw, a.tempK, a.poh, a.br, a.bw);
    char f[1024]; snprintf(f, sizeof f, "%s/sysinfo-probe-wl.bin", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");  // 当前用户的临时目录
    size_t ch = 8 << 20; char *buf = malloc(ch); arc4random_buf(buf, ch);
    int fd = open(f, O_CREAT | O_TRUNC | O_RDWR, 0644); fcntl(fd, F_NOCACHE, 1);
    for (int i = 0; i < 32; i++) write(fd, buf, ch);
    fcntl(fd, F_FULLFSYNC); lseek(fd, 0, SEEK_SET);
    while (read(fd, buf, ch) > 0) {}
    close(fd); unlink(f);
    sleep(1);
    take(&b);
    printf("after:  SMART units r=%llu w=%llu temp=%dK poh=%u | block bytes r=%llu w=%llu\n", b.ur, b.uw, b.tempK, b.poh, b.br, b.bw);
    double smw = (double)(b.uw - a.uw) * 512000, smr = (double)(b.ur - a.ur) * 512000;
    printf("delta:  SMART written=%.1f MB read=%.1f MB | block written=%.1f MB read=%.1f MB (ops w=%llu r=%llu) | workload 268.4 MB each way\n",
        smw / 1e6, smr / 1e6, (double)(b.bw - a.bw) / 1e6, (double)(b.br - a.br) / 1e6, b.opsw - a.opsw, b.opsr - a.opsr);
    return 0;
}
