#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
extern int IOReportChannelGetFormat(CFDictionaryRef);
static volatile int stop=0;
static void* spin(void*a){ volatile double x=0; while(!stop){x+=1.0;} return 0; }
static void cs(CFStringRef s,char*b,int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
int main(int argc,char**argv){
  int busy = argc>1;
  CFDictionaryRef all=IOReportCopyAllChannels(0,0);
  CFArrayRef ac=CFDictionaryGetValue(all,CFSTR("IOReportChannels"));
  printf("IOReportCopyAllChannels: %ld channels\n",(long)CFArrayGetCount(ac));
  CFDictionaryRef em=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
  CFMutableDictionaryRef chans=CFDictionaryCreateMutableCopy(NULL,0,em);
  CFArrayRef ec=CFDictionaryGetValue(chans,CFSTR("IOReportChannels"));
  printf("Energy Model channels: %ld\n",(long)CFArrayGetCount(ec));
  CFMutableDictionaryRef sub=NULL;
  IOReportSubscriptionRef s=IOReportCreateSubscription(NULL,chans,&sub,0,NULL);
  printf("subscription=%p\n",(void*)s);
  pthread_t th[6];
  if(busy) for(int i=0;i<6;i++) pthread_create(&th[i],0,spin,0);
  CFDictionaryRef a=IOReportCreateSamples(s,sub,NULL);
  usleep(1000000);
  CFDictionaryRef b=IOReportCreateSamples(s,sub,NULL);
  stop=1; if(busy) for(int i=0;i<6;i++) pthread_join(th[i],0);
  CFDictionaryRef d=IOReportCreateSamplesDelta(a,b,NULL);
  CFArrayRef items=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
  long nz=0,n=CFArrayGetCount(items);
  for(long i=0;i<n;i++){ CFDictionaryRef it=CFArrayGetValueAtIndex(items,i);
    int64_t v=IOReportSimpleGetIntegerValue(it,NULL);
    char g[128],sg[128],nm[128],u[32]; cs(IOReportChannelGetSubGroup(it),sg,128); cs(IOReportChannelGetChannelName(it),nm,128); cs(IOReportChannelGetUnitLabel(it),u,32);
    if(v!=0){ nz++; if(nz<=40) printf("  [%s] %s = %lld %s\n",sg,nm,(long long)v,u); }
  }
  printf("busy=%d nonzero=%ld of %ld\n",busy,nz,n);
  return 0;
}
