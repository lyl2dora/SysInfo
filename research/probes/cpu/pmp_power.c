// Probe: CPU cluster power estimate from IOReport "PMP0"/"Energy" power-bucket histograms (MACC0, MACC1, PACC + SRAM).
// Each 1s: residency-weighted mean of bucket labels (label = bucket upper edge; also midpoint). Logs wall time for cross-check vs Energy Model.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
#include <time.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
static double wall(){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
int main(int argc, char** argv){
  int secs = argc>1?atoi(argv[1]):10;
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("Energy"), 0,0,0);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  CFDictionaryRef prev = IOReportCreateSamples(sub,subbed,NULL); double t0=wall(), tp=t0; double cumUpper=0, cumMid=0;
  printf("time      dt    MACC0   MACC1   PACC   (SRAM: M0 M1 P)  CPU_total_upper  CPU_total_mid   [W]\n");
  while(wall()-t0 < secs){
    sleep(1);
    CFDictionaryRef cur = IOReportCreateSamples(sub,subbed,NULL); double t=wall();
    CFArrayRef arr = CFDictionaryGetValue(IOReportCreateSamplesDelta(prev,cur,NULL), CFSTR("IOReportChannels"));
    double up[8]={0}, mid[8]={0}; const char* want[]={"MACC0","MACC1","PACC","MACC0 SRAM","MACC1 SRAM","PACC SRAM"};
    for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c = CFArrayGetValueAtIndex(arr,i); char n[64]; CFStringGetCString(IOReportChannelGetChannelName(c),n,64,kCFStringEncodingUTF8);
      int w=-1; for(int k=0;k<6;k++) if(!strcmp(n,want[k])) w=k; if(w<0) continue;
      int cnt = IOReportStateGetCount(c); double sw=0, su=0, sm=0, prevEdge=0;
      for(int k=0;k<cnt;k++){ char st[32]; CFStringGetCString(IOReportStateGetNameForIndex(c,k),st,32,kCFStringEncodingUTF8); double edge=atof(st); double r=(double)IOReportStateGetResidency(c,k);
        sw+=r; su+=r*edge; sm+=r*(edge+prevEdge)/2; prevEdge=edge; }
      if(sw>0){ up[w]=su/sw; mid[w]=sm/sw; } }
    double tu=0, tm=0; for(int k=0;k<6;k++){ tu+=up[k]; tm+=mid[k]; }
    cumUpper += tu*(t-tp); cumMid += tm*(t-tp);
    time_t tt=(time_t)t; char ts[16]; strftime(ts,16,"%H:%M:%S",localtime(&tt));
    printf("%s %.2f  %6.2f  %6.2f  %6.2f   (%.2f %.2f %.2f)   %6.2f          %6.2f   cumJ_upper=%.0f cumJ_mid=%.0f\n", ts, t-tp, up[0], up[1], up[2], up[3], up[4], up[5], tu, tm, cumUpper, cumMid);
    fflush(stdout); CFRelease(prev); prev=cur; tp=t;
  }
  return 0;
}
