// snapslots.c - semantics of the IOReportCreateSnapshotDeltas scalar argument (1 vs 2: independent kernel snapshot slots?)
// Uses AGX "GPU Energy" (live) while a tiny own Metal-free CPU spin is absent; the GPU is driven by nothing, so we also
// compare against CreateSamples absolute values to check delta = abs difference since that slot's previous call.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFErrorRef*);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFErrorRef*);
CFDictionaryRef IOReportCreateSnapshotDeltas(uint64_t, IOReportSubscriptionRef, CFMutableDictionaryRef, CFErrorRef*);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static long long ge(CFDictionaryRef d){ if(!d) return -1; CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); for(CFIndex i=0;i<CFArrayGetCount(a);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); char nm[64]; CFStringGetCString(IOReportChannelGetChannelName(c),nm,64,kCFStringEncodingUTF8); if(!strcmp(nm,"GPU Energy")) return IOReportSimpleGetIntegerValue(c,NULL);} return -2; }
int main(void){ CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0); CFMutableDictionaryRef sb=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sb,0,NULL);
  #define CS(l) { CFDictionaryRef s=IOReportCreateSamples(sub,sb,NULL); printf("%-28s CS abs GPU Energy=%lld\n",l,ge(s)); CFRelease(s); }
  #define SD(a,l) { CFErrorRef e=NULL; CFDictionaryRef s=IOReportCreateSnapshotDeltas(a,sub,sb,&e); printf("%-28s SD(%d) GPU Energy=%lld%s\n",l,a,ge(s),s?"":" (NULL)"); if(s) CFRelease(s); }
  CS("t0"); SD(1,"t0 first SD(1)"); SD(2,"t0 first SD(2)"); CS("t0");
  sleep(2); CS("t2"); SD(1,"t2 SD(1)"); sleep(2); CS("t4"); SD(2,"t4 SD(2) (4 s since its last)"); SD(1,"t4 SD(1) (2 s since its last)"); CS("t4");
  sleep(1); SD(1,"t5 SD(1)"); SD(1,"t5 SD(1) again immediately"); SD(2,"t5 SD(2)"); CS("t5");
  // many slot-1 calls: does 'max number of snapshots' trigger?
  int fails=0; for(int i=0;i<2000;i++){ CFErrorRef e=NULL; CFDictionaryRef s=IOReportCreateSnapshotDeltas(1+(i&1),sub,sb,&e); if(!s) fails++; else CFRelease(s);} printf("2000 alternating SD(1)/SD(2) calls: %d failures\n",fails);
  return 0; }
