// snapdelta.c - try the macOS 27 libIOReport export IOReportCreateSnapshotDeltas.
// Signature recovered from disassembly (dyld_info -disassemble /usr/lib/libIOReport.dylib, see libIOReport_disasm.txt):
//   CFDictionaryRef IOReportCreateSnapshotDeltas(uint64_t arg, IOReportSubscriptionRef sub, CFMutableDictionaryRef subbedChannels, CFErrorRef *err)
//   -> IOConnectCallMethod(sub->conn, selector 5, scalars {sub->id, arg}) then IOReportCreateSamplesRaw(subbedChannels, CFData(sub->sharedbuf), err)
// Compared with IOReportCreateSamples (selector 3, scalars {sub->id}). Read-only (IOReport user client), no privileges.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/time.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFErrorRef*);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFErrorRef*);
CFDictionaryRef IOReportCreateSnapshotDeltas(uint64_t, IOReportSubscriptionRef, CFMutableDictionaryRef, CFErrorRef*);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
int32_t IOReportChannelGetFormat(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static double wall(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
static void cs(CFStringRef s, char *b, int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
static void show(const char*lab, CFDictionaryRef d, CFErrorRef err){
  if(!d){ char e[256]="(no err)"; if(err){ CFStringRef ds=CFErrorCopyDescription(err); cs(ds,e,256); CFRelease(ds);} printf("%s: NULL  err=%s\n",lab,e); return; }
  CFArrayRef a=CFDictionaryGetValue(d,CFSTR("IOReportChannels")); long long cpu=-1,gpu0=-1,ane=-1,dram=-1,ge=-1,mc=-1; int n=a?(int)CFArrayGetCount(a):-1, nz=0;
  for(int i=0;i<n;i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); char nm[64]; cs(IOReportChannelGetChannelName(c),nm,64); long long v=IOReportSimpleGetIntegerValue(c,NULL); if(v) nz++;
    if(!strcmp(nm,"CPU Energy")) cpu=v; else if(!strcmp(nm,"GPU0")) gpu0=v; else if(!strcmp(nm,"ANE0")) ane=v; else if(!strcmp(nm,"DRAM0")) dram=v; else if(!strcmp(nm,"GPU Energy")) ge=v; else if(!strcmp(nm,"MCPU0")) mc=v; }
  printf("%s: %d channels (%d non-zero)  CPU Energy=%lld GPU0=%lld ANE0=%lld DRAM0=%lld MCPU0=%lld | AGX GPU Energy=%lld\n",lab,n,nz,cpu,gpu0,ane,dram,mc,ge); }
int main(int argc,char**argv){
  int secs = argc>1?atoi(argv[1]):10;
  void *h=dlopen("/usr/lib/libIOReport.dylib",RTLD_NOW); void *f=dlsym(h,"IOReportCreateSnapshotDeltas");
  long slide=(long)f-0x192D270A4L; printf("IOReportCreateSnapshotDeltas=%p slide=%#lx\n",f,slide);
  unsigned long stubs[]={0x1980fc150,0x1980fc160,0x1980fc170,0x1980ec720,0x1980ec9a0}; 
  for(int i=0;i<5;i++){ Dl_info di; void*p=(void*)(stubs[i]+slide); if(dladdr(p,&di)) printf("  call target %#lx -> %s (%s)\n",stubs[i],di.dli_sname?di.dli_sname:"?",di.dli_fname); }
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
  CFMutableDictionaryRef sb=NULL; CFErrorRef err=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sb,0,&err);
  printf("sub=%p\n",sub); if(!sub) return 1;
  CFDictionaryRef s0=IOReportCreateSamples(sub,sb,NULL); show("CreateSamples",s0,NULL);
  uint64_t args[]={0,1,2,3,4,8,16,100,1000,0xffffffff};
  for(int k=0;k<10;k++){ err=NULL; CFDictionaryRef d=IOReportCreateSnapshotDeltas(args[k],sub,sb,&err); char lab[64]; snprintf(lab,64,"SnapshotDeltas(arg=%llu)",args[k]); show(lab,d,err); if(d) CFRelease(d); }
  printf("--- time series: every 1 s, SnapshotDeltas(arg=0) and (arg=1) vs CreateSamples\n");
  double t0=wall();
  while(wall()-t0<secs){ sleep(1); char lab[64];
    err=NULL; CFDictionaryRef d0=IOReportCreateSnapshotDeltas(0,sub,sb,&err); snprintf(lab,64,"t=%4.0f SD(0)",wall()-t0); show(lab,d0,err); if(d0) CFRelease(d0);
    err=NULL; CFDictionaryRef d1=IOReportCreateSnapshotDeltas(1,sub,sb,&err); snprintf(lab,64,"t=%4.0f SD(1)",wall()-t0); show(lab,d1,err); if(d1) CFRelease(d1);
    CFDictionaryRef s=IOReportCreateSamples(sub,sb,NULL); snprintf(lab,64,"t=%4.0f CS   ",wall()-t0); show(lab,s,NULL); CFRelease(s); }
  return 0; }
