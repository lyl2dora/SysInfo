// Review probe: cross-check CPU power sources every 0.5 s: (a) IOReport Energy Model "CPU Energy" (mJ, PMGR), (b) SMC PHPC/PPSM/PMVC/PSTR (W, READ-ONLY),
// (c) own-process rusage_info_v6 ri_energy_nj (our spinning threads only). Phases: idle 6s, 18x USER_INITIATED spin for LOADSECS, idle 8s.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <sys/time.h>
#include <time.h>
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
static atomic_int stop_flag=0;
static void* spin(void* a){ pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED,0); volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
static uint64_t myenergy(){ struct rusage_info_v6 r; if(proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t*)&r)) return 0; return r.ri_energy_nj; }
int main(int argc, char** argv){
  int loadsecs = argc>1?atoi(argv[1]):20;
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")); if(IOServiceOpen(svc, mach_task_self(), 0, &conn)) return 1;
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0,0,0);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  double t0=wall(), tp=t0; long long lastE=-1; double integPHPC=0, integPSTR=0; uint64_t e0=myenergy(), ep=e0; pthread_t th[18]; int loaded=0;
  printf("  t     phase  PHPC(W) PPSM(W) PMVC(W) PSTR(W) | ownRusage(W) | EnergyModel CPU Energy (mJ) delta | integral PHPC since start (J)\n");
  while(1){
    double t=wall(), el=t-t0;
    if(!loaded && el>=6 && el<6+loadsecs){ atomic_store(&stop_flag,0); for(int i=0;i<18;i++) pthread_create(&th[i],NULL,spin,NULL); loaded=1; }
    if(loaded==1 && el>=6+loadsecs){ atomic_store(&stop_flag,1); for(int i=0;i<18;i++) pthread_join(th[i],NULL); loaded=2; }
    if(el > 6+loadsecs+8) break;
    CFDictionaryRef s = IOReportCreateSamples(sub,subbed,NULL); CFArrayRef arr = CFDictionaryGetValue(s, CFSTR("IOReportChannels")); long long e=0;
    for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c = CFArrayGetValueAtIndex(arr,i); char n[64]; CFStringGetCString(IOReportChannelGetChannelName(c),n,64,kCFStringEncodingUTF8); if(!strcmp(n,"CPU Energy")) e=IOReportSimpleGetIntegerValue(c,NULL); }
    CFRelease(s);
    double phpc=smcf("PHPC"), ppsm=smcf("PPSM"), pmvc=smcf("PMVC"), pstr=smcf("PSTR"); uint64_t en=myenergy();
    double dt=t-tp; integPHPC+=phpc*dt; integPSTR+=pstr*dt;
    printf("%5.1f  %-6s %7.2f %7.2f %7.2f %7.2f | %7.2f | %lld %s%lld | %.1f\n", el, loaded==1?"LOAD":"idle", phpc, ppsm, pmvc, pstr, dt>0? (en-ep)/1e9/dt:0, e, (lastE>=0 && e!=lastE)?"CHANGED +":"+", lastE>=0? e-lastE:0, integPHPC);
    fflush(stdout); lastE=e; ep=en; tp=t; usleep(500000);
  }
  IOServiceClose(conn); return 0;
}
