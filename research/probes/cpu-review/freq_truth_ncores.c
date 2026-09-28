// Review probe: ground-truth core clock via a dependent ADD chain (1 cycle latency each => adds / thread-CPU-seconds = MHz),
// compared, in the same window, with (a) IOReport "CPU Core Performance States" residency x pmgr voltage-states*-sram table (the
// method the original report and Stats use) and (b) rusage_info_v6 ri_cycles / cpu-time for this process. Read-only.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
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
static double tblM[32], tblS[32]; static int nM=0, nS=0;
static void loadTables(){ io_iterator_t it; IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it); io_object_t s;
  while((s=IOIteratorNext(it))){ char nm[128]; IORegistryEntryGetName(s,nm); if(!strcmp(nm,"pmgr")){
    CFDataRef m=IORegistryEntryCreateCFProperty(s,CFSTR("voltage-states22-sram"),0,0), p=IORegistryEntryCreateCFProperty(s,CFSTR("voltage-states5-sram"),0,0);
    const uint32_t* a=(const uint32_t*)CFDataGetBytePtr(m); nM=(int)CFDataGetLength(m)/8; for(int i=0;i<nM;i++) tblM[i]=a[2*i]/1000.0;
    const uint32_t* b=(const uint32_t*)CFDataGetBytePtr(p); nS=(int)CFDataGetLength(p)/8; for(int i=0;i<nS;i++) tblS[i]=b[2*i]/1000.0; }
    IOObjectRelease(s);} }
static atomic_int stop_flag=0; static qos_class_t gq; static double tfreq[64]; static int tq[64];
static void* worker(void* arg){ int id=(int)(long)arg; pthread_set_qos_class_self_np(gq,0);
  uint64_t x=0, iters=0; uint64_t c0=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
  while(!atomic_load_explicit(&stop_flag, memory_order_relaxed)){ for(int k=0;k<1000;k++){ __asm__ volatile(".rept 100\n add %0, %0, #1\n .endr\n" : "+r"(x)); } iters+=1000; }
  uint64_t c1=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); tfreq[id] = (double)iters*100.0/((c1-c0)/1e9)/1e6; (void)x; return NULL; }
static uint64_t cyc(double* cpu){ struct rusage_info_v6 r; proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t*)&r); *cpu=(r.ri_user_time+r.ri_system_time)*125.0/3/1e9; return r.ri_cycles; }
int main(){
  loadTables(); printf("tables: M %d states %.0f..%.0f MHz, Super %d states %.0f..%.0f MHz\n", nM, tblM[0], tblM[nM-1], nS, tblS[0], tblS[nS-1]);
  CFMutableDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"),0,0,0);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,ch,&subbed,0,NULL);
  struct { const char* name; qos_class_t q; int n; } ph[] = { {"1x USER_INTERACTIVE", QOS_CLASS_USER_INTERACTIVE, 1}, {"2x USER_INTERACTIVE", QOS_CLASS_USER_INTERACTIVE, 2}, {"4x USER_INTERACTIVE", QOS_CLASS_USER_INTERACTIVE, 4}, {"6x USER_INTERACTIVE", QOS_CLASS_USER_INTERACTIVE, 6} };
  for(int p=0;p<4;p++){
    gq=ph[p].q; atomic_store(&stop_flag,0); pthread_t th[64]; for(int i=0;i<ph[p].n;i++) pthread_create(&th[i],NULL,worker,(void*)(long)i);
    usleep(500000);
    double cpu0, cpu1; uint64_t k0=cyc(&cpu0); CFDictionaryRef s1=IOReportCreateSamples(sub,subbed,NULL);
    sleep(3);
    CFDictionaryRef s2=IOReportCreateSamples(sub,subbed,NULL); uint64_t k1=cyc(&cpu1);
    atomic_store(&stop_flag,1); for(int i=0;i<ph[p].n;i++) pthread_join(th[i],NULL);
    printf("\n== %s ==\n add-chain MHz per thread:", ph[p].name); for(int i=0;i<ph[p].n;i++) printf(" %.0f", tfreq[i]); printf("\n");
    printf(" rusage ri_cycles/cpu-time (whole process, same 3 s window): %.0f MHz\n", (k1-k0)/(cpu1-cpu0)/1e6);
    CFArrayRef arr = CFDictionaryGetValue(IOReportCreateSamplesDelta(s1,s2,NULL), CFSTR("IOReportChannels"));
    printf(" IOReport residency x table, per core (active%%, avg active MHz):");
    for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char n[32]; CFStringGetCString(IOReportChannelGetChannelName(c),n,32,kCFStringEncodingUTF8);
      int isS = n[0]=='P'; double* t = isS? tblS: tblM; int tn = isS? nS: nM; int cnt=IOReportStateGetCount(c); double tot=0, act=0, f=0;
      for(int k=0;k<cnt;k++){ char st[32]; CFStringGetCString(IOReportStateGetNameForIndex(c,k),st,32,kCFStringEncodingUTF8); double r=(double)IOReportStateGetResidency(c,k); tot+=r;
        if(st[0]=='V'){ int vi=atoi(st+1); if(vi<tn){ act+=r; f+=r*t[vi]; } } }
      if(i%6==0) printf("\n   "); printf(" %s:%3.0f%%/%4.0f", n, tot?100*act/tot:0, act? f/act:0); }
    printf("\n"); CFRelease(s1); CFRelease(s2); sleep(3);
  }
  return 0;
}
