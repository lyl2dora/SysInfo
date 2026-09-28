// snapglobal.c - are IOReportCreateSnapshotDeltas slots shared across processes? A fresh process with a fresh subscription calls
// slot 2 (which the long-running snapwatch process polls every 5 s) and slot 1 (last used ~minutes ago by snapslots), and prints
// the AGX "GPU Energy" delta each returns; compare with AGX absolute to infer the baseline time.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFErrorRef*);
CFDictionaryRef IOReportCreateSnapshotDeltas(uint64_t, IOReportSubscriptionRef, CFMutableDictionaryRef, CFErrorRef*);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFErrorRef*);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static long long ge(CFDictionaryRef d,const char*w){ if(!d) return -1; CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); for(CFIndex i=0;i<CFArrayGetCount(a);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); char nm[64]; CFStringGetCString(IOReportChannelGetChannelName(c),nm,64,kCFStringEncodingUTF8); if(!strcmp(nm,w)) return IOReportSimpleGetIntegerValue(c,NULL);} return -2; }
int main(void){ CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0); CFMutableDictionaryRef sb=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sb,0,NULL);
  CFDictionaryRef a=IOReportCreateSamples(sub,sb,NULL); CFDictionaryRef s2=IOReportCreateSnapshotDeltas(2,sub,sb,NULL); CFDictionaryRef s1=IOReportCreateSnapshotDeltas(1,sub,sb,NULL);
  printf("fresh process: AGX abs=%lld nJ, CPU Energy abs=%lld mJ | first SD(2) AGX delta=%lld nJ CPU delta=%lld | first SD(1) AGX delta=%lld nJ CPU delta=%lld\n",
     ge(a,"GPU Energy"),ge(a,"CPU Energy"),ge(s2,"GPU Energy"),ge(s2,"CPU Energy"),ge(s1,"GPU Energy"),ge(s1,"CPU Energy")); return 0; }
