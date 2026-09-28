// snapwatch.c - long run: every 5 s call IOReportCreateSnapshotDeltas(slot 2) on an Energy Model subscription and IOReportCreateSamples
// on four subscriptions created with options 0, 1, 0x10, 0xFFFFFFFF (4th arg; disassembly shows it is never read).
// Logs PMGR deltas (CPU Energy, GPU0, ANE0, DRAM0, AVE0) returned by the snapshot path and whether any non-default subscription
// sees a PMGR value that differs from the default one. Read-only; no privileges.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFErrorRef*);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFErrorRef*);
CFDictionaryRef IOReportCreateSnapshotDeltas(uint64_t, IOReportSubscriptionRef, CFMutableDictionaryRef, CFErrorRef*);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static const char *names[]={"CPU Energy","GPU0","ANE0","DRAM0","AVE0","GPU Energy"};
static void get(CFDictionaryRef d,long long v[6]){ for(int k=0;k<6;k++) v[k]=-1; if(!d) return; CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(a);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); char nm[64]; CFStringGetCString(IOReportChannelGetChannelName(c),nm,64,kCFStringEncodingUTF8);
    for(int k=0;k<6;k++) if(!strcmp(nm,names[k])) v[k]=IOReportSimpleGetIntegerValue(c,NULL); } }
int main(int argc,char**argv){ int secs=atoi(argv[1]); uint64_t opts[4]={0,1,0x10,0xFFFFFFFF}; IOReportSubscriptionRef sub[4]; CFMutableDictionaryRef sb[4];
  for(int i=0;i<4;i++){ CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0); sb[i]=NULL; CFErrorRef e=NULL; sub[i]=IOReportCreateSubscription(NULL,ch,&sb[i],opts[i],&e); printf("subscription options=%#llx -> %p\n",opts[i],sub[i]); }
  { CFDictionaryRef d=IOReportCreateSnapshotDeltas(2,sub[0],sb[0],NULL); if(d) CFRelease(d); } // prime slot 2
  time_t t0=time(NULL); int beat=0;
  while(time(NULL)-t0<secs){ sleep(5); long long sd[6], cs[4][6]; CFDictionaryRef d=IOReportCreateSnapshotDeltas(2,sub[0],sb[0],NULL); get(d,sd); if(d) CFRelease(d);
    for(int i=0;i<4;i++){ CFDictionaryRef s=IOReportCreateSamples(sub[i],sb[i],NULL); get(s,cs[i]); CFRelease(s); }
    int diff=0; for(int i=1;i<4;i++) for(int k=0;k<5;k++) if(cs[i][k]!=cs[0][k]) diff=1;
    char ts[16]; time_t n=time(NULL); strftime(ts,16,"%H:%M:%S",localtime(&n));
    if(sd[0]||sd[1]||sd[2]||sd[3]||sd[4]||diff||(++beat%24==0))
      printf("%s SD(2) delta: CPU %+lld mJ GPU0 %+lld ANE0 %+lld DRAM0 %+lld AVE0 %+lld AGX %+lld nJ | CS abs CPU(opt0)=%lld opt1=%lld opt0x10=%lld optFFFF=%lld %s\n",
        ts,sd[0],sd[1],sd[2],sd[3],sd[4],sd[5],cs[0][0],cs[1][0],cs[2][0],cs[3][0],diff?"<-- options subscriptions DIFFER":"");
    fflush(stdout); }
  return 0; }
