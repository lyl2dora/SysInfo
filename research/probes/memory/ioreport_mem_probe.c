// ioreport_mem_probe.c - does IOReport (private libIOReport) expose DRAM/memory-controller bandwidth channels on M5 Pro?
// Lists all groups, then samples channels in memory-related groups twice (1 s apart) and prints deltas.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int IOReportChannelGetFormat(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern void IOReportIterate(CFDictionaryRef, int (^)(CFDictionaryRef));
static const char* s(CFStringRef r, char*b, int n){ b[0]=0; if(r) CFStringGetCString(r,b,n,kCFStringEncodingUTF8); return b; }
static int memgroup(const char*g){ const char*k[]={"AMC","DCS","PMP","DRAM","Bandwidth","BW","Memory","MCC","SoC Stats",NULL}; for(int i=0;k[i];i++) if(strcasestr(g,k[i])) return 1; return 0; }
int main(void){
  CFDictionaryRef all = IOReportCopyAllChannels(0,0);
  CFArrayRef ch = all ? CFDictionaryGetValue(all, CFSTR("IOReportChannels")) : NULL;
  long n = ch?CFArrayGetCount(ch):0; printf("IOReportCopyAllChannels: %ld channels\n", n);
  CFMutableSetRef groups = CFSetCreateMutable(NULL,0,&kCFTypeSetCallBacks);
  for(long i=0;i<n;i++){ CFStringRef g=IOReportChannelGetGroup(CFArrayGetValueAtIndex(ch,i)); if(g) CFSetAddValue(groups,g); }
  long gc=CFSetGetCount(groups); const void**gv=malloc(gc*sizeof(void*)); CFSetGetValues(groups,gv);
  char b[256],b2[256],b3[256]; printf("groups (%ld):",gc); for(long i=0;i<gc;i++) printf(" [%s]",s(gv[i],b,256)); printf("\n");
  for(long i=0;i<gc;i++){ s(gv[i],b,256); if(!memgroup(b)) continue;
    CFDictionaryRef d = IOReportCopyChannelsInGroup(gv[i],NULL,0,0,0); if(!d) continue;
    CFMutableDictionaryRef md = CFDictionaryCreateMutableCopy(NULL,0,d); CFMutableDictionaryRef subbed=NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL,md,&subbed,0,NULL);
    if(!sub){ printf("group %s: subscription failed\n",b); continue; }
    CFDictionaryRef s1=IOReportCreateSamples(sub,subbed,NULL); sleep(1); CFDictionaryRef s2=IOReportCreateSamples(sub,subbed,NULL);
    CFDictionaryRef dl=IOReportCreateSamplesDelta(s1,s2,NULL);
    __block int shown=0, total=0, nz=0;
    IOReportIterate(dl, ^int(CFDictionaryRef c){ total++; int f=IOReportChannelGetFormat(c);
      int64_t v = (f==1)?IOReportSimpleGetIntegerValue(c,0):0; if(v) nz++;
      if(shown<25 && (f!=1 || v)) { char x1[256],x2[256],x3[256],x4[64]; printf("  %s / %s / %s fmt=%d unit=%s delta1s=%lld\n",s(IOReportChannelGetGroup(c),x1,256),s(IOReportChannelGetSubGroup(c),x2,256),s(IOReportChannelGetChannelName(c),x3,256),f,s(IOReportChannelGetUnitLabel(c),x4,64),(long long)v); shown++; }
      return 0; });
    s(gv[i],b,256); printf("group [%s]: %d channels, %d simple channels with nonzero 1s delta\n",b,total,nz);
  }
  return 0;
}
