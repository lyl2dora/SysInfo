// Review probe: can IOBlockStorageDriver "Total Time" be turned into a %busy? Compare summed Total Time delta to wall time.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
static long long g(CFDictionaryRef d, CFStringRef k) { long long v = 0; CFNumberRef n = CFDictionaryGetValue(d, k); if (n) CFNumberGetValue(n, kCFNumberLongLongType, &v); return v; }
static void snap(long long *tt, long long *ops) {
    io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEmbeddedNVMeBlockDevice"), &it);
    io_service_t dev = IOIteratorNext(it); IOObjectRelease(it); io_registry_entry_t drv; IORegistryEntryGetChildEntry(dev, kIOServicePlane, &drv);
    CFDictionaryRef s = IORegistryEntryCreateCFProperty(drv, CFSTR("Statistics"), NULL, 0);
    *tt = g(s, CFSTR("Total Time (Read)")) + g(s, CFSTR("Total Time (Write)")); *ops = g(s, CFSTR("Operations (Read)")) + g(s, CFSTR("Operations (Write)"));
    CFRelease(s); IOObjectRelease(drv); IOObjectRelease(dev);
}
int main(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    const char *f = "/tmp/sysinfo-probes/disk-review/busy.bin";
    size_t ch = 8 << 20; char *buf = malloc(ch); arc4random_buf(buf, ch);
    long long t0, o0, t1, o1; snap(&t0, &o0); uint64_t w0 = mach_absolute_time();
    int fd = open(f, O_CREAT | O_TRUNC | O_RDWR, 0644); fcntl(fd, F_NOCACHE, 1);
    for (int i = 0; i < 64; i++) write(fd, buf, ch);
    fcntl(fd, F_FULLFSYNC); lseek(fd, 0, SEEK_SET); while (read(fd, buf, ch) > 0) {}
    close(fd); unlink(f);
    uint64_t w1 = mach_absolute_time(); snap(&t1, &o1);
    double wall = (double)(w1 - w0) * tb.numer / tb.denom / 1e6;
    printf("512 MiB write+fsync+512 MiB uncached read: wall=%.1f ms, dTotalTime(R+W)=%.1f ms, dOps=%lld -> TotalTime/wall=%.0f%%, avg latency=%.3f ms/op\n",
        wall, (t1 - t0) / 1e6, o1 - o0, 100.0 * (t1 - t0) / 1e6 / wall, (t1 - t0) / 1e6 / (double)(o1 - o0));
    return 0;
}
