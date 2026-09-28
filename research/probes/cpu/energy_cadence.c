// Probe: measure update cadence of IOReport "Energy Model" PMGR counters (CPU Energy) — logs each change with wall-clock time.
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
  int secs = argc>1?atoi(argv[1]):600; double period = argc>2?atof(argv[2]):1.0;
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0,0,0);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  long long last=-1; double lastT=0, t0=wall();
  while(wall()-t0 < secs){
    CFDictionaryRef s = IOReportCreateSamples(sub,subbed,NULL); CFArrayRef arr = CFDictionaryGetValue(s, CFSTR("IOReportChannels"));
    for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c = CFArrayGetValueAtIndex(arr,i); char n[64]; CFStringGetCString(IOReportChannelGetChannelName(c),n,64,kCFStringEncodingUTF8);
      if(!strcmp(n,"CPU Energy")){ long long v = IOReportSimpleGetIntegerValue(c,NULL); double t=wall();
        if(v!=last){ time_t tt=(time_t)t; char ts[32]; strftime(ts,32,"%H:%M:%S",localtime(&tt));
          if(last>=0) printf("%s t=+%.1fs CPU Energy changed by %lld mJ after %.1fs => avg %.2f W over that interval\n", ts, t-t0, v-last, t-lastT, (v-last)/1000.0/(t-lastT));
          else printf("%s start value %lld mJ\n", ts, v);
          fflush(stdout); last=v; lastT=t; } } }
    CFRelease(s); usleep((useconds_t)(period*1e6));
  }
  printf("end after %ds\n", secs); return 0;
}
