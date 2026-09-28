// dram_bw_review.c - adversarial check of IOReport PMP0 "DCS BW" as a DRAM-bandwidth signal:
//  (1) print histogram state names (bin semantics), (2) idle, (3) cache-resident memcpy (256 KiB/thread: huge copy rate, ~no DRAM),
//  (4) DRAM read-only streaming (1 GiB/thread), (5) DRAM memcpy (256 MiB/thread, like the original probe). 4 threads, own process only.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
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
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern void IOReportIterate(CFDictionaryRef, int (^)(CFDictionaryRef));
static IOReportSubscriptionRef sub; static CFMutableDictionaryRef subbed;
static void report(CFDictionaryRef dl, const char*label){ 
  IOReportIterate(dl, ^int(CFDictionaryRef c){ char nm[64], sg[64]; CFStringGetCString(IOReportChannelGetChannelName(c),nm,64,kCFStringEncodingUTF8); CFStringGetCString(IOReportChannelGetSubGroup(c),sg,64,kCFStringEncodingUTF8);
    if(strcmp(sg,"DCS BW")) return 0; int n=IOReportStateGetCount(c); double num=0,den=0; int hi=0; 
    for(int i=0;i<n;i++){ double r=(double)IOReportStateGetResidency(c,i); num+=r*(16.0*i+8.0); den+=r; if(r>0) hi=i; }
    printf("  %-22s %-11s events=%6.0f  mean(bin-mid)=%6.1f GB/s  highest-nonempty-bin=%d\n",label,nm,den,den>0?num/den:-1,hi); return 0; }); }
static volatile int stop=0, mode=0; static _Atomic long long bytes=0; static size_t SZ; static char *bufs[8];
static void* work(void*a){ long i=(long)a; char*s=bufs[2*i],*d=bufs[2*i+1]; volatile uint64_t sink=0;
  while(!stop){ if(mode==1){ const uint64_t*q=(const uint64_t*)s; uint64_t acc=0; for(size_t k=0;k<SZ/8;k+=8) acc+=q[k]+q[k+1]+q[k+2]+q[k+3]+q[k+4]+q[k+5]+q[k+6]+q[k+7]; sink+=acc; atomic_fetch_add(&bytes,(long long)SZ);} 
    else { memcpy(d,s,SZ); atomic_fetch_add(&bytes,2*(long long)SZ);} } return NULL; }
static void phase(const char*label,int m,size_t sz){ SZ=sz; mode=m; stop=0; atomic_store(&bytes,0); pthread_t t[4];
  if(sz){ for(int i=0;i<8;i++){ bufs[i]=malloc(sz); memset(bufs[i],i+1,sz);} for(long i=0;i<4;i++) pthread_create(&t[i],NULL,work,(void*)i); usleep(300000); }
  long long b0=atomic_load(&bytes); uint64_t t0=mach_absolute_time(); CFDictionaryRef a=IOReportCreateSamples(sub,subbed,NULL); usleep(1500000);
  CFDictionaryRef b=IOReportCreateSamples(sub,subbed,NULL); uint64_t t1=mach_absolute_time(); long long b1=atomic_load(&bytes);
  if(sz){ stop=1; for(int i=0;i<4;i++) pthread_join(t[i],NULL); for(int i=0;i<8;i++) free(bufs[i]); }
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double secs=(t1-t0)*tb.numer/tb.denom/1e9;
  printf("%s: CPU-side traffic %.1f GB/s\n",label,(b1-b0)/secs/1e9); report(IOReportCreateSamplesDelta(a,b,NULL),label); }
int main(void){
  CFDictionaryRef d=IOReportCopyChannelsInGroup(CFSTR("PMP0"),CFSTR("DCS BW"),0,0,0); CFMutableDictionaryRef md=CFDictionaryCreateMutableCopy(NULL,0,d);
  sub=IOReportCreateSubscription(NULL,md,&subbed,0,NULL);
  CFDictionaryRef s=IOReportCreateSamples(sub,subbed,NULL);
  IOReportIterate(s, ^int(CFDictionaryRef c){ char nm[64]; CFStringGetCString(IOReportChannelGetChannelName(c),nm,64,kCFStringEncodingUTF8); if(strcmp(nm,"AMCC RD+WR")) return 0;
    int n=IOReportStateGetCount(c); printf("state names (%d):",n); for(int i=0;i<n;i++){ char sn[32]; CFStringGetCString(IOReportStateGetNameForIndex(c,i),sn,32,kCFStringEncodingUTF8); if(i<4||i>n-3) printf(" [%d]=%s",i,sn);} printf("\n"); return 0; });
  phase("idle",0,0);
  phase("cache-resident memcpy",0,256<<10);
  phase("DRAM read-only 1GiB",1,1ull<<30);
  phase("DRAM memcpy 256MiB",0,256<<20);
  return 0; }
