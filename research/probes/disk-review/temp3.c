// Review probe: sample NAND temperature from 3 sources at the same instant, 3 times, 2 s apart.
// SMART (public NVMe plugin), HID (private IOHIDEventSystemClient, NO matching dict: iterate all services, filter Product),
// SMC read-only by key name (TH0x/TH0a/TH0b/TH0B), decoding type from key-info (flt vs sp78 etc).
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef; typedef struct __IOHIDServiceClient *IOHIDServiceClientRef; typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct { UInt32 key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } SMCKeyData;
static io_connect_t conn;
static int smc(const char *k, char *type, double *val) {
    SMCKeyData in = {0}, out = {0}; size_t os = sizeof out;
    in.key = ((UInt32)k[0] << 24) | ((UInt32)k[1] << 16) | ((UInt32)k[2] << 8) | (UInt32)k[3]; in.data8 = 9;
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof in, &out, &os) || out.result) return -1;
    UInt32 t = out.keyInfo.dataType, sz = out.keyInfo.dataSize;
    type[0] = t >> 24; type[1] = t >> 16; type[2] = t >> 8; type[3] = t; type[4] = 0;
    in.keyInfo.dataSize = sz; in.data8 = 5; memset(&out, 0, sizeof out); os = sizeof out;
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof in, &out, &os) || out.result) return -2;
    if (!strcmp(type, "flt ")) { float f; memcpy(&f, out.bytes, 4); *val = f; }
    else if (!strcmp(type, "sp78")) { *val = (double)(int16_t)((out.bytes[0] << 8) | out.bytes[1]) / 256.0; }
    else *val = -999;
    return 0;
}
int main(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")); IOServiceOpen(s, mach_task_self(), 0, &conn);
    IOHIDEventSystemClientRef hc = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    for (int round = 0; round < 3; round++) {
        // SMART
        io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEmbeddedNVMeBlockDevice"), &it);
        io_service_t dev = IOIteratorNext(it); IOObjectRelease(it);
        IOCFPlugInInterface **pl; SInt32 sc; IONVMeSMARTInterface **sm; NVMeSMARTData d;
        IOCreatePlugInInterfaceForService(dev, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pl, &sc);
        (*pl)->QueryInterface(pl, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&sm);
        (*sm)->SMARTReadData(sm, &d); (*sm)->Release(sm); IODestroyPlugInInterface(pl); IOObjectRelease(dev);
        printf("round %d: SMART composite=%dC", round, (int)d.TEMPERATURE - 273);
        // HID: all services, filter by Product containing NAND
        CFArrayRef sv = IOHIDEventSystemClientCopyServices(hc); int nt = 0;
        for (long i = 0; sv && i < CFArrayGetCount(sv); i++) {
            IOHIDServiceClientRef x = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(sv, i);
            CFStringRef p = IOHIDServiceClientCopyProperty(x, CFSTR("Product")); char b[128] = ""; if (p) { CFStringGetCString(p, b, 128, kCFStringEncodingUTF8); CFRelease(p); }
            if (!strstr(b, "NAND")) continue;
            IOHIDEventRef e = IOHIDServiceClientCopyEvent(x, 15, 0, 0);
            if (e) { printf(" | HID '%s'=%.2fC", b, IOHIDEventGetFloatValue(e, 15 << 16)); CFRelease(e); nt++; }
        }
        if (sv) printf(" (HID services total=%ld, NAND=%d)", CFArrayGetCount(sv), nt);
        if (sv) CFRelease(sv);
        const char *keys[] = {"TH0x", "TH0a", "TH0b", "TH0B", "TH1x", "TH0A"};
        for (int k = 0; k < 6; k++) { char ty[5]; double v; int r = smc(keys[k], ty, &v); if (r == 0) printf(" | SMC %s[%s]=%.2f", keys[k], ty, v); else printf(" | SMC %s absent", keys[k]); }
        printf("\n");
        sleep(2);
    }
    IOServiceClose(conn);
    return 0;
}
