// Review probe: watch IOReport "Energy Model" PMGR counters (CPU Energy, GPU0, DRAM0) vs AGX "GPU Energy" (live) for N seconds.
// Logs every change with wall time, plus GPU0(mJ) vs GPU Energy(nJ) to measure how far behind the PMGR batch is. Read-only.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static double wall(){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
int main(int argc, char** argv){
  int secs = argc>1?atoi(argv[1]):1800; double period = argc>2?atof(argv[2]):2.0;
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0,0,0);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  long long lastCPU=-1, lastGPU0=-1; double lastT=0, t0=wall(); long long lastGE=0; int nsamp=0;
  while(wall()-t0 < secs){
    CFDictionaryRef s = IOReportCreateSamples(sub,subbed,NULL); CFArrayRef arr = CFDictionaryGetValue(s, CFSTR("IOReportChannels"));
    long long cpu=0,gpu0=0,dram=0,ge=0;
    for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c = CFArrayGetValueAtIndex(arr,i); char n[64]; CFStringGetCString(IOReportChannelGetChannelName(c),n,64,kCFStringEncodingUTF8);
      long long v = IOReportSimpleGetIntegerValue(c,NULL);
      if(!strcmp(n,"CPU Energy")) cpu=v; else if(!strcmp(n,"GPU0")) gpu0=v; else if(!strcmp(n,"DRAM0")) dram=v; else if(!strcmp(n,"GPU Energy")) ge=v; }
    double t=wall(); time_t tt=(time_t)t; char ts[32]; strftime(ts,32,"%H:%M:%S",localtime(&tt)); nsamp++;
    if(lastCPU<0) printf("%s start CPU Energy=%lld mJ GPU0=%lld mJ DRAM0=%lld mJ | AGX GPU Energy=%lld mJ (PMGR GPU0 lags AGX by %lld mJ)\n", ts, cpu, gpu0, dram, ge/1000000, ge/1000000-gpu0);
    else if(cpu!=lastCPU || gpu0!=lastGPU0) printf("%s +%.0fs CHANGE: CPU Energy +%lld mJ, GPU0 +%lld mJ after %.0fs unchanged (%d samples) | now PMGR GPU0 lags AGX by %lld mJ\n", ts, t-t0, cpu-lastCPU, gpu0-lastGPU0, t-lastT, nsamp, ge/1000000-gpu0);
    if(cpu!=lastCPU || gpu0!=lastGPU0){ lastCPU=cpu; lastGPU0=gpu0; lastT=t; nsamp=0; }
    fflush(stdout); lastGE=ge; CFRelease(s); usleep((useconds_t)(period*1e6));
  }
  time_t tt=time(NULL); char ts[32]; strftime(ts,32,"%H:%M:%S",localtime(&tt)); printf("%s end after %ds; last CPU Energy=%lld\n", ts, secs, lastCPU); return 0;
}
