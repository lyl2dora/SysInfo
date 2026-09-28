// Review probe: PMP0 "Volt-Temp HM" PACC0_V_T residency (voltage_temperature bins) while 1 vs 6 Super cores spin (USER_INTERACTIVE),
// to see whether the Super cluster voltage drops below the V19 (4608 MHz, 1100 mV core / 1120 mV sram) point with more active cores. Read-only.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
static atomic_int stop_flag=0;
static void* spin(void* a){ pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0); volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
int main(){
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("PMP0"),CFSTR("Volt-Temp HM"),0,0,0); CFMutableDictionaryRef sd=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sd,0,NULL);
  int ns[]={1,2,6};
  for(int p=0;p<3;p++){
    atomic_store(&stop_flag,0); pthread_t th[8]; for(int i=0;i<ns[p];i++) pthread_create(&th[i],NULL,spin,NULL); usleep(500000);
    CFDictionaryRef a=IOReportCreateSamples(sub,sd,NULL); sleep(2); CFDictionaryRef b=IOReportCreateSamples(sub,sd,NULL);
    atomic_store(&stop_flag,1); for(int i=0;i<ns[p];i++) pthread_join(th[i],NULL);
    CFArrayRef arr=CFDictionaryGetValue(IOReportCreateSamplesDelta(a,b,NULL),CFSTR("IOReportChannels"));
    printf("== %d Super thread(s) ==\n", ns[p]);
    for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char n[32]; CFStringGetCString(IOReportChannelGetChannelName(c),n,32,kCFStringEncodingUTF8);
      if(strcmp(n,"PACC0_V_T")) continue; double tot=0; int cnt=IOReportStateGetCount(c); for(int k=0;k<cnt;k++) tot+=IOReportStateGetResidency(c,k);
      printf("  %s:", n); for(int k=0;k<cnt;k++){ double r=IOReportStateGetResidency(c,k); if(r/tot>0.02){ char st[32]; CFStringGetCString(IOReportStateGetNameForIndex(c,k),st,32,kCFStringEncodingUTF8); printf(" %s=%.0f%%", st, 100*r/tot);} } printf("\n"); }
    sleep(3);
  }
  return 0;
}
