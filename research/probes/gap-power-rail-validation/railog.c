// railog.c - READ-ONLY power-rail logger for gap-power-rail-validation.
// Logs at 1 Hz (10 Hz inside [t10a,t10b)) : every SMC 'P*' flt key, AGX "GPU Energy" (live), PMGR Energy Model change
// detection (+ full snapshot of all Energy Model channels on every change), PMP0 "Energy"/"Power" histogram means,
// and AppleSmartBattery.PowerTelemetryData accumulators.  SMC access uses only selectors 8/9/5 (index/keyinfo/read). No writes.
// build: xcrun clang -O2 -framework IOKit -framework CoreFoundation -lIOReport railog.c -o railog
// usage: railog <outprefix> <duration_s> [t10a_epoch t10b_epoch]
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <sys/time.h>
#include <libproc.h>
#include <sys/resource.h>

// ---------------- SMC (read-only) ----------------
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t smc_conn;
static void s4(uint32_t k,char*o){ o[0]=k>>24;o[1]=k>>16;o[2]=k>>8;o[3]=k;o[4]=0; }
static uint32_t k4(const char *s){ return (uint32_t)s[0]<<24|(uint32_t)s[1]<<16|(uint32_t)s[2]<<8|(uint32_t)s[3]; }
static kern_return_t smc_call(SMCParam*in,SMCParam*out){ size_t sz=sizeof(SMCParam); return IOConnectCallStructMethod(smc_conn,2,in,sizeof(SMCParam),out,&sz); }
static int smc_info(uint32_t key, SMCKeyInfo *ki){ SMCParam in={0},out={0}; in.key=key; in.data8=9; if(smc_call(&in,&out)!=KERN_SUCCESS||out.result) return -1; *ki=out.keyInfo; return 0; }
static int smc_readf(uint32_t key, float *f){ SMCParam in={0},out={0}; in.key=key; in.keyInfo.dataSize=4; in.data8=5;
  if(smc_call(&in,&out)!=KERN_SUCCESS||out.result) return -1; memcpy(f,out.bytes,4); return 0; }
#define MAXK 128
static uint32_t pkeys[MAXK]; static int npk=0;

// ---------------- IOReport (private) ----------------
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
void IOReportMergeChannels(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int32_t IOReportChannelGetFormat(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
int32_t IOReportStateGetCount(CFDictionaryRef);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
static void cs(CFStringRef s, char *b, int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
static double wall(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }

#define MAXCH 512
typedef struct { char name[64]; char drv[64]; char unit[8]; long long v; } Ch;
static Ch emPrev[MAXCH]; static int nem=0;
// PMP0 histogram columns
#define MAXP 32
static char pmpName[MAXP][64]; static int npmp=0;
static int pmpIndex(const char*n){ for(int i=0;i<npmp;i++) if(!strcmp(pmpName[i],n)) return i; if(npmp<MAXP){ strcpy(pmpName[npmp],n); return npmp++; } return -1; }
static double stateWatts(const char *nm){ // "2W", "0.250W", "500mW"
  char *e; double v=strtod(nm,&e); if(e==nm) return NAN; while(*e==' ') e++; if(!strncmp(e,"mW",2)) return v/1000; if(*e=='W') return v; return NAN; }

static const char *telKeys[] = {"AccumulatedSystemPowerIn","SystemPowerInAccumulatorCount","AccumulatedWallEnergyEstimate",
  "AccumulatedSystemEnergyConsumed","AccumulatedSystemLoad","SystemLoadAccumulatorCount","AccumulatedAdapterEfficiencyLoss","SystemPowerIn","WallEnergyEstimate", NULL};

int main(int argc, char **argv){
  if(argc<3){ fprintf(stderr,"usage: railog <outprefix> <duration_s> [t10a t10b]\n"); return 1; }
  const char *pre=argv[1]; double dur=atof(argv[2]); double t10a = argc>4?atof(argv[3]):0, t10b = argc>4?atof(argv[4]):0;
  char fn[1024];
  snprintf(fn,sizeof fn,"%s.csv",pre); FILE *fo=fopen(fn,"w");
  snprintf(fn,sizeof fn,"%s_pmgr.txt",pre); FILE *fp=fopen(fn,"w");
  // SMC open + enumerate P* flt keys
  io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
  if(!s || IOServiceOpen(s,mach_task_self(),0,&smc_conn)!=KERN_SUCCESS){ fprintf(stderr,"SMC open failed\n"); return 2; }
  IOObjectRelease(s);
  { SMCKeyInfo ki; SMCParam in={0},out={0}; in.key=k4("#KEY"); in.keyInfo.dataSize=4; in.data8=5; smc_call(&in,&out);
    int cnt=(uint32_t)out.bytes[0]<<24|out.bytes[1]<<16|out.bytes[2]<<8|out.bytes[3];
    for(int i=0;i<cnt && npk<MAXK;i++){ SMCParam a={0},b={0}; a.data8=8; a.data32=i; if(smc_call(&a,&b)!=KERN_SUCCESS) continue;
      char nm[5]; s4(b.key,nm); if(nm[0]!='P') continue; if(smc_info(b.key,&ki)) continue; char t[5]; s4(ki.dataType,t);
      if(!strcmp(t,"flt ") && ki.dataSize==4) pkeys[npk++]=b.key; }
    fprintf(stderr,"SMC keys=%d, P* flt=%d\n",cnt,npk); }
  // IOReport subscriptions
  CFMutableDictionaryRef emCh = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL,0,0,0);
  CFMutableDictionaryRef emSubbed=NULL; IOReportSubscriptionRef emSub = IOReportCreateSubscription(NULL, emCh, &emSubbed, 0, NULL);
  CFMutableDictionaryRef pCh = IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("Energy"),0,0,0);
  CFMutableDictionaryRef pCh2 = IOReportCopyChannelsInGroup(CFSTR("PMP0"), CFSTR("Power"),0,0,0);
  if(pCh2) IOReportMergeChannels(pCh, pCh2, NULL);
  CFMutableDictionaryRef pSubbed=NULL; IOReportSubscriptionRef pSub = IOReportCreateSubscription(NULL, pCh, &pSubbed, 0, NULL);
  if(!emSub||!pSub){ fprintf(stderr,"subscription failed em=%p pmp=%p\n",emSub,pSub); return 3; }
  io_service_t bat = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
  // header
  fprintf(fo,"epoch,dt,rate");
  for(int i=0;i<npk;i++){ char nm[5]; s4(pkeys[i],nm); fprintf(fo,",%s",nm); }
  fprintf(fo,",AGX_GE_nJ,AGX_W,pmgr_nchanged,CPU_mJ,GPU0_mJ,ANE0_mJ,DRAM0_mJ,AVE0_mJ,nonPMGR_other_uJ");
  // PMP0 columns are established from the first delta; write placeholder marker, full names go to a sidecar
  fprintf(fo,",PMP0_means...");
  for(int k=0;telKeys[k];k++) fprintf(fo,",T_%s",telKeys[k]);
  fprintf(fo,"\n");
  CFDictionaryRef pPrev = IOReportCreateSamples(pSub, pSubbed, NULL);
  double t0=wall(), tPrev=t0; long long agxPrev=-1; int first=1; long n=0;
  double next = floor(t0)+1.0;
  while(1){
    double now=wall(); if(now < next){ usleep((useconds_t)((next-now)*1e6)); }
    double t=wall(); if(t - t0 > dur) break;
    int fast = (t>=t10a && t<t10b);
    next += fast?0.1:1.0; if(next < wall()) next = floor(wall()*10)/10+ (fast?0.1:1.0);
    // SMC
    float pv[MAXK]; for(int i=0;i<npk;i++){ if(smc_readf(pkeys[i],&pv[i])) pv[i]=NAN; }
    // Energy Model
    CFDictionaryRef es = IOReportCreateSamples(emSub, emSubbed, NULL);
    CFArrayRef arr = CFDictionaryGetValue(es, CFSTR("IOReportChannels"));
    long long agx=0, cpu=0,gpu0=0,ane=0,dram=0,ave=0, other=0; int nchg=0; char chgList[4096]; chgList[0]=0;
    int nc=(int)CFArrayGetCount(arr); if(nc>MAXCH) nc=MAXCH;
    for(int i=0;i<nc;i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char nm[64],dv[64],un[8]; cs(IOReportChannelGetChannelName(c),nm,64); cs(IOReportChannelGetDriverName(c),dv,64); cs(IOReportChannelGetUnitLabel(c),un,8);
      long long v = IOReportSimpleGetIntegerValue(c,NULL);
      if(first){ strcpy(emPrev[i].name,nm); strcpy(emPrev[i].drv,dv); strcpy(emPrev[i].unit,un); emPrev[i].v=v; }
      else if(emPrev[i].v!=v){ if(strstr(dv,"PMGR")){ nchg++; if(strlen(chgList)<3900){ char b[128]; snprintf(b,128," %s%+lld",nm,v-emPrev[i].v); strcat(chgList,b);} } emPrev[i].v=v; }
      if(!strcmp(nm,"GPU Energy")) agx=v; else if(!strcmp(nm,"CPU Energy")) cpu=v; else if(!strcmp(nm,"GPU0")) gpu0=v; else if(!strcmp(nm,"ANE0")) ane=v; else if(!strcmp(nm,"DRAM0")) dram=v; else if(!strcmp(nm,"AVE0")) ave=v;
      else if(!strstr(dv,"PMGR")) other += !strcmp(un,"uJ")? v : (!strcmp(un,"mJ")? v*1000 : (!strcmp(un,"nJ")? v/1000 : 0));
    }
    if(first || nchg){ fprintf(fp,"=== %.3f %s nchanged=%d\n", t, first?"START":"CHANGE", nchg); if(nchg) fprintf(fp,"changed:%s\n",chgList);
      for(int i=0;i<nc;i++) fprintf(fp,"%s|%s|%s|%lld\n",emPrev[i].name,emPrev[i].unit,emPrev[i].drv,emPrev[i].v); fflush(fp); }
    if(first) nem=nc;
    CFRelease(es);
    // PMP0 histograms
    CFDictionaryRef pCur = IOReportCreateSamples(pSub, pSubbed, NULL);
    CFDictionaryRef pd = IOReportCreateSamplesDelta(pPrev, pCur, NULL); CFRelease(pPrev); pPrev=pCur;
    double pmean[MAXP]; for(int i=0;i<MAXP;i++) pmean[i]=NAN;
    CFArrayRef parr = CFDictionaryGetValue(pd, CFSTR("IOReportChannels"));
    for(CFIndex i=0;i<CFArrayGetCount(parr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(parr,i); char nm[64],sg[32],full[96]; cs(IOReportChannelGetChannelName(c),nm,64); cs(IOReportChannelGetSubGroup(c),sg,32);
      snprintf(full,96,"%s:%s",sg,nm); int ix=pmpIndex(full); if(ix<0) continue;
      int f=IOReportChannelGetFormat(c); if(f!=2){ continue; }
      int ns=IOReportStateGetCount(c); double num=0,den=0; for(int k=0;k<ns;k++){ char sn[32]; cs(IOReportStateGetNameForIndex(c,k),sn,32); double w=stateWatts(sn); double r=(double)IOReportStateGetResidency(c,k); if(isnan(w)) continue; num+=w*r; den+=r; }
      pmean[ix] = den>0? num/den : 0; }
    CFRelease(pd);
    // Telemetry
    long long tel[16]={0};
    if(bat){ CFTypeRef p = IORegistryEntryCreateCFProperty(bat, CFSTR("PowerTelemetryData"), kCFAllocatorDefault, 0);
      if(p && CFGetTypeID(p)==CFDictionaryGetTypeID()){ for(int k=0;telKeys[k];k++){ CFStringRef ks=CFStringCreateWithCString(NULL,telKeys[k],kCFStringEncodingUTF8); CFNumberRef nv=CFDictionaryGetValue(p,ks); if(nv) CFNumberGetValue(nv,kCFNumberSInt64Type,&tel[k]); CFRelease(ks);} }
      if(p) CFRelease(p); }
    double dt = t - tPrev; tPrev=t;
    fprintf(fo,"%.3f,%.3f,%d",t,first?0:dt,fast?10:1);
    for(int i=0;i<npk;i++) fprintf(fo,",%.4f",pv[i]);
    fprintf(fo,",%lld,%.4f,%d,%lld,%lld,%lld,%lld,%lld,%lld", agx, (agxPrev<0||dt<=0)?NAN:(agx-agxPrev)/1e9/dt, nchg, cpu,gpu0,ane,dram,ave,other);
    fprintf(fo,",|"); for(int i=0;i<npmp;i++) fprintf(fo,"%s%.3f", i?";":"", pmean[i]);
    for(int k=0;telKeys[k];k++) fprintf(fo,",%lld",tel[k]);
    fprintf(fo,"\n");
    if(n%10==0) fflush(fo);
    agxPrev=agx; first=0; n++;
  }
  // PMP0 column names sidecar
  snprintf(fn,sizeof fn,"%s_pmpcols.txt",pre); FILE *fc=fopen(fn,"w"); for(int i=0;i<npmp;i++) fprintf(fc,"%d %s\n",i,pmpName[i]); fclose(fc);
  // final snapshot
  { CFDictionaryRef es = IOReportCreateSamples(emSub, emSubbed, NULL); CFArrayRef arr = CFDictionaryGetValue(es, CFSTR("IOReportChannels"));
    fprintf(fp,"=== %.3f END\n", wall()); for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char nm[64],dv[64],un[8]; cs(IOReportChannelGetChannelName(c),nm,64); cs(IOReportChannelGetDriverName(c),dv,64); cs(IOReportChannelGetUnitLabel(c),un,8); fprintf(fp,"%s|%s|%s|%lld\n",nm,un,dv,IOReportSimpleGetIntegerValue(c,NULL)); } }
  struct rusage_info_v6 ru; proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t*)&ru);
  fprintf(stderr,"railog done: %ld samples, own energy %.3f J, own cpu %.2f s\n", n, ru.ri_energy_nj/1e9, (ru.ri_user_time+ru.ri_system_time)/1e9);
  fclose(fo); fclose(fp); return 0;
}
