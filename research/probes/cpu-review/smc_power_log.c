// Review helper (READ-ONLY SMC + IOReport): log SMC PHPC/PPSM/PMVC/PSTR and the live AGX "GPU Energy" (nJ) power once per second.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
typedef struct { char major, minor, build, reserved[1]; uint16_t release; } Vers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } KeyInfo;
typedef struct { uint32_t key; Vers vers; PLimit pLimitData; KeyInfo keyInfo; char result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t conn;
static int call(SMCParam* in, SMCParam* out){ size_t o=sizeof(SMCParam); return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCParam), out, &o); }
static double smcf(const char* k){ SMCParam in={0}, out={0}; in.key=(k[0]<<24)|(k[1]<<16)|(k[2]<<8)|k[3]; in.data8=9; if(call(&in,&out)||out.result) return -1;
  uint32_t sz=out.keyInfo.dataSize; memset(&in,0,sizeof in); in.key=(k[0]<<24)|(k[1]<<16)|(k[2]<<8)|k[3]; in.keyInfo.dataSize=sz; in.data8=5; if(call(&in,&out)||out.result) return -2; float f; memcpy(&f,out.bytes,4); return f; }
static double wall(){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
int main(int argc, char** argv){
  int secs = argc>1?atoi(argv[1]):16;
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")); if(IOServiceOpen(svc, mach_task_self(), 0, &conn)) return 1;
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0,0,0); CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  long long pg=-1; double pt=0, t0=wall();
  for(int i=0;i<=secs;i++){
    CFDictionaryRef s = IOReportCreateSamples(sub,subbed,NULL); CFArrayRef arr = CFDictionaryGetValue(s, CFSTR("IOReportChannels")); long long g=0;
    for(CFIndex j=0;j<CFArrayGetCount(arr);j++){ CFDictionaryRef c = CFArrayGetValueAtIndex(arr,j); char n[64]; CFStringGetCString(IOReportChannelGetChannelName(c),n,64,kCFStringEncodingUTF8); if(!strcmp(n,"GPU Energy")) g=IOReportSimpleGetIntegerValue(c,NULL); }
    CFRelease(s); double t=wall();
    printf("t=%4.1f PHPC=%6.2f PPSM=%6.2f PMVC=%6.2f PSTR=%6.2f | AGX GPU power=%6.2f W\n", t-t0, smcf("PHPC"), smcf("PPSM"), smcf("PMVC"), smcf("PSTR"), pg>=0? (g-pg)/1e9/(t-pt):0);
    fflush(stdout); pg=g; pt=t; sleep(1);
  }
  return 0;
}
