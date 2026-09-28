// dram_bw_probe.c - estimate DRAM bandwidth from IOReport PMP0 "DCS BW / AMCC RD+WR" histogram (16 GB/s bins),
// idle vs. during a self-generated 1.5 s memcpy load (own process only), compared with measured memcpy throughput.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
extern void IOReportIterate(CFDictionaryRef, int (^)(CFDictionaryRef));
static IOReportSubscriptionRef sub; static CFMutableDictionaryRef subbed;
static double est(CFDictionaryRef dl, const char*want){ __block double num=0, den=0;
  IOReportIterate(dl, ^int(CFDictionaryRef c){ char nm[64], sg[64]; CFStringGetCString(IOReportChannelGetChannelName(c),nm,64,kCFStringEncodingUTF8); CFStringGetCString(IOReportChannelGetSubGroup(c),sg,64,kCFStringEncodingUTF8);
    if(strcmp(sg,"DCS BW")||strcmp(nm,want)) return 0; int n=IOReportStateGetCount(c);
    for(int i=0;i<n;i++){ double r=(double)IOReportStateGetResidency(c,i); num += r*(16.0*i+8.0); den += r; } return 0; });
  return den>0?num/den:-1; }
#include <stdatomic.h>
static volatile int stop=0; static _Atomic long long copied=0; static char *bufs[8];
static void* load(void*a){ long i=(long)a; size_t sz=256<<20; char*s=bufs[2*i],*d=bufs[2*i+1]; while(!stop){ memcpy(d,s,sz); atomic_fetch_add(&copied,(long long)sz); } return NULL; }
int main(void){
  CFDictionaryRef d = IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("DCS BW"), 0,0,0);
  CFMutableDictionaryRef md = CFDictionaryCreateMutableCopy(NULL,0,d); sub = IOReportCreateSubscription(NULL, md, &subbed, 0, NULL);
  CFDictionaryRef a = IOReportCreateSamples(sub, subbed, NULL); usleep(1500000); CFDictionaryRef b = IOReportCreateSamples(sub, subbed, NULL);
  CFDictionaryRef dl = IOReportCreateSamplesDelta(a,b,NULL);
  printf("idle 1.5s: est DRAM RD=%.1f WR=%.1f RD+WR=%.1f GB/s (bin-midpoint estimate, 16 GB/s bins)\n", est(dl,"AMCC RD"), est(dl,"AMCC WR"), est(dl,"AMCC RD+WR"));
  for(int i=0;i<8;i++){ bufs[i]=malloc(256<<20); memset(bufs[i],i+1,256<<20);} pthread_t t[4]; for(long i=0;i<4;i++) pthread_create(&t[i],NULL,load,(void*)i); usleep(300000);
  double c0=(double)atomic_load(&copied); uint64_t t0=mach_absolute_time(); a = IOReportCreateSamples(sub, subbed, NULL); usleep(1500000); b = IOReportCreateSamples(sub, subbed, NULL); uint64_t t1=mach_absolute_time(); double c1=(double)atomic_load(&copied);
  stop=1; for(int i=0;i<4;i++) pthread_join(t[i],NULL);
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double secs=(t1-t0)*tb.numer/tb.denom/1e9;
  dl = IOReportCreateSamplesDelta(a,b,NULL);
  printf("4-thread memcpy load: measured memcpy traffic (read+write)=%.1f GB/s (approx, racy counter); est DRAM RD=%.1f WR=%.1f RD+WR=%.1f GB/s\n", 2*(c1-c0)/secs/1e9, est(dl,"AMCC RD"), est(dl,"AMCC WR"), est(dl,"AMCC RD+WR"));
  return 0;
}
