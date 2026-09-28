// Review probe: is the ANS GetLogPage(0x01/0x03) failure a buffer-size artifact? Try several numDWords (read-only Get Log Page).
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
int main(void) {
    io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEmbeddedNVMeBlockDevice"), &it);
    io_service_t dev = IOIteratorNext(it); IOObjectRelease(it);
    IOCFPlugInInterface **pl; SInt32 sc; IONVMeSMARTInterface **sm;
    IOCreatePlugInInterfaceForService(dev, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pl, &sc);
    (*pl)->QueryInterface(pl, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&sm);
    static uint8_t buf[16384];
    uint32_t pages[] = {0x01, 0x02, 0x03, 0x05, 0x06};
    uint32_t sizes[] = {15, 127, 1023};
    for (int p = 0; p < 5; p++) for (int s = 0; s < 3; s++) {
        memset(buf, 0, sizeof buf);
        IOReturn r = (*sm)->GetLogPage(sm, buf, pages[p], sizes[s]);
        int nz = 0; for (int i = 0; i < (int)(sizes[s] + 1) * 4; i++) nz += buf[i] != 0;
        printf("ANS GetLogPage(0x%02x, numDWords=%u) r=0x%08x nonzero_bytes=%d\n", pages[p], sizes[s], r, nz);
    }
    (*sm)->Release(sm); IODestroyPlugInInterface(pl); IOObjectRelease(dev);
    return 0;
}
