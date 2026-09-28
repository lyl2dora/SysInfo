// pstr_log.c - READ-ONLY: log SMC PSTR (system total power, W) every 200 ms for N seconds (selectors 9 + 5 only).
// build: xcrun clang -O1 -o pstr_log pstr_log.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct { UInt32 key; vers_t vers; plimit_t pLimitData; keyinfo_t keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } SMCKeyData_t;
static io_connect_t conn;
static int rd(const char *k, float *v) { SMCKeyData_t in = {0}, out = {0}; size_t o = sizeof out; UInt32 key = (UInt32)k[0] << 24 | (UInt32)k[1] << 16 | (UInt32)k[2] << 8 | (UInt32)k[3];
  in.key = key; in.data8 = 9; if (IOConnectCallStructMethod(conn, 2, &in, sizeof in, &out, &o) || out.result) return -1; UInt32 sz = out.keyInfo.dataSize;
  memset(&in, 0, sizeof in); in.key = key; in.keyInfo.dataSize = sz; in.data8 = 5; memset(&out, 0, sizeof out); o = sizeof out;
  if (IOConnectCallStructMethod(conn, 2, &in, sizeof in, &out, &o) || out.result) return -2; memcpy(v, out.bytes, 4); return 0; }
int main(int argc, char **argv) { double secs = argc > 1 ? atof(argv[1]) : 60;
  io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")); IOServiceOpen(s, mach_task_self(), 0, &conn); IOObjectRelease(s);
  for (int i = 0; i < secs * 5; i++) { float v = 0; rd("PSTR", &v); char b[32]; struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); time_t t = ts.tv_sec; strftime(b, sizeof b, "%H:%M:%S", localtime(&t));
    printf("%s.%03ld PSTR %.3f\n", b, ts.tv_nsec / 1000000, v); fflush(stdout); usleep(200000); }
  return 0; }
