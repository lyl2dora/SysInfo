// ptlog.c - 功耗与散热模块边界补测用的只读记录器（基于 gap-power-rail-validation/railog.c）。
// 每秒记录一次（第二轮起加入 R 开头的功耗轨键 RP*）：
//   - SMC 中首字母为 P/T/F/V/I、类型为 flt 的全部键（只用 selector 2 的 cmd 8/9/5，不写 SMC）；
//   - IOReport Energy Model：AGX「GPU Energy」实时值，PMGR 通道变化检测（每次变化写一份全通道快照）；
//   - AppleSmartBattery.PowerTelemetryData 累加器；
//   - 热压力（notify com.apple.system.thermalpressurelevel）；
//   - 每段读取的线程 CPU 与墙钟耗时。
// build: xcrun clang -O2 -framework IOKit -framework CoreFoundation -lIOReport ptlog.c -o ptlog
// usage: ptlog <outprefix> <duration_s>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <sys/time.h>
#include <libproc.h>
#include <notify.h>
#include <time.h>
#include <sys/resource.h>

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
#define MAXK 1024
static uint32_t keys[MAXK]; static uint8_t attrs[MAXK]; static int nk=0;

typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static void cs(CFStringRef s, char *b, int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
static double wall(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
static double tcpu(void){ struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }

#define MAXCH 1024
typedef struct { char name[64]; char drv[64]; char unit[8]; long long v; } Ch;
static Ch emPrev[MAXCH];

static const char *telKeys[] = {"AccumulatedSystemPowerIn","SystemPowerInAccumulatorCount","AccumulatedWallEnergyEstimate",
  "AccumulatedSystemEnergyConsumed","AccumulatedSystemLoad","SystemLoadAccumulatorCount","AccumulatedAdapterEfficiencyLoss","SystemPowerIn","WallEnergyEstimate", NULL};

int main(int argc, char **argv){
  if(argc<3){ fprintf(stderr,"usage: ptlog <outprefix> <duration_s>\n"); return 1; }
  const char *pre=argv[1]; double dur=atof(argv[2]);
  char fn[1024];
  snprintf(fn,sizeof fn,"%s.csv",pre); FILE *fo=fopen(fn,"w");
  snprintf(fn,sizeof fn,"%s_pmgr.txt",pre); FILE *fp=fopen(fn,"w");
  snprintf(fn,sizeof fn,"%s_keys.txt",pre); FILE *fk=fopen(fn,"w");
  io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
  if(!s || IOServiceOpen(s,mach_task_self(),0,&smc_conn)!=KERN_SUCCESS){ fprintf(stderr,"SMC open failed\n"); return 2; }
  IOObjectRelease(s);
  { SMCKeyInfo ki; SMCParam in={0},out={0}; in.key=k4("#KEY"); in.keyInfo.dataSize=4; in.data8=5; smc_call(&in,&out);
    int cnt=(uint32_t)out.bytes[0]<<24|out.bytes[1]<<16|out.bytes[2]<<8|out.bytes[3];
    for(int i=0;i<cnt && nk<MAXK;i++){ SMCParam a={0},b={0}; a.data8=8; a.data32=i; if(smc_call(&a,&b)!=KERN_SUCCESS) continue;
      char nm[5]; s4(b.key,nm); if(!strchr("PTFVIR",nm[0])) continue; if(smc_info(b.key,&ki)) continue; char t[5]; s4(ki.dataType,t);
      if(strcmp(t,"flt ") || ki.dataSize!=4) continue;
      float f; if(smc_readf(b.key,&f)) { fprintf(fk,"%s READFAIL attr=0x%02x\n",nm,ki.dataAttributes); continue; }
      keys[nk]=b.key; attrs[nk]=ki.dataAttributes; nk++; fprintf(fk,"%s attr=0x%02x first=%.4f\n",nm,ki.dataAttributes,f); }
    fprintf(stderr,"SMC keys=%d, logged flt P/T/F/V/I=%d\n",cnt,nk); fclose(fk); }
  CFMutableDictionaryRef emCh = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL,0,0,0);
  CFMutableDictionaryRef emSubbed=NULL; IOReportSubscriptionRef emSub = emCh? IOReportCreateSubscription(NULL, emCh, &emSubbed, 0, NULL) : NULL;
  if(!emSub){ fprintf(stderr,"Energy Model subscription failed\n"); return 3; }
  io_service_t bat = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
  int ntok=0; notify_register_check("com.apple.system.thermalpressurelevel",&ntok);
  fprintf(fo,"epoch,dt,smc_cpu_ms,smc_wall_ms,em_cpu_ms,tel_cpu_ms,thermal_pressure");
  for(int i=0;i<nk;i++){ char nm[5]; s4(keys[i],nm); fprintf(fo,",%s",nm); }
  fprintf(fo,",AGX_GE_nJ,AGX_W,pmgr_nchanged,CPU_mJ,GPU0_mJ,ANE0_mJ,DRAM0_mJ,AVE0_mJ");
  for(int k=0;telKeys[k];k++) fprintf(fo,",T_%s",telKeys[k]);
  fprintf(fo,"\n");
  double t0=wall(), tPrev=t0; long long agxPrev=-1; int first=1; long n=0;
  double next = floor(t0)+1.0;
  while(1){
    double now=wall(); if(now < next) usleep((useconds_t)((next-now)*1e6));
    double t=wall(); if(t - t0 > dur) break;
    next += 1.0; if(next < wall()) next = floor(wall())+1.0;
    double c0=tcpu(), w0=wall();
    static float pv[MAXK]; for(int i=0;i<nk;i++){ if(smc_readf(keys[i],&pv[i])) pv[i]=NAN; }
    double c1=tcpu(), w1=wall();
    CFDictionaryRef es = IOReportCreateSamples(emSub, emSubbed, NULL);
    CFArrayRef arr = CFDictionaryGetValue(es, CFSTR("IOReportChannels"));
    long long agx=-1, cpu=0,gpu0=0,ane=0,dram=0,ave=0; int nchg=0; char chgList[8192]; chgList[0]=0;
    int nc=(int)CFArrayGetCount(arr); if(nc>MAXCH) nc=MAXCH;
    for(int i=0;i<nc;i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char nm[64],dv[64],un[8]; cs(IOReportChannelGetChannelName(c),nm,64); cs(IOReportChannelGetDriverName(c),dv,64); cs(IOReportChannelGetUnitLabel(c),un,8);
      long long v = IOReportSimpleGetIntegerValue(c,NULL);
      if(first){ strcpy(emPrev[i].name,nm); strcpy(emPrev[i].drv,dv); strcpy(emPrev[i].unit,un); emPrev[i].v=v; }
      else if(emPrev[i].v!=v){ if(strstr(dv,"PMGR")){ nchg++; if(strlen(chgList)<8000){ char b[128]; snprintf(b,128," %s%+lld",nm,v-emPrev[i].v); strcat(chgList,b);} } emPrev[i].v=v; }
      if(!strcmp(nm,"GPU Energy")) agx=v; else if(!strcmp(nm,"CPU Energy")) cpu=v; else if(!strcmp(nm,"GPU0")) gpu0=v; else if(!strcmp(nm,"ANE0")) ane=v; else if(!strcmp(nm,"DRAM0")) dram=v; else if(!strcmp(nm,"AVE0")) ave=v;
    }
    if(first || nchg){ fprintf(fp,"=== %.3f %s nchanged=%d\n", t, first?"START":"CHANGE", nchg); if(nchg) fprintf(fp,"changed:%s\n",chgList);
      for(int i=0;i<nc;i++) fprintf(fp,"%s|%s|%s|%lld\n",emPrev[i].name,emPrev[i].unit,emPrev[i].drv,emPrev[i].v); fflush(fp); }
    CFRelease(es);
    double c2=tcpu();
    long long tel[16]={0};
    if(bat){ CFTypeRef p = IORegistryEntryCreateCFProperty(bat, CFSTR("PowerTelemetryData"), kCFAllocatorDefault, 0);
      if(p && CFGetTypeID(p)==CFDictionaryGetTypeID()){ for(int k=0;telKeys[k];k++){ CFStringRef ks=CFStringCreateWithCString(NULL,telKeys[k],kCFStringEncodingUTF8); CFNumberRef nv=CFDictionaryGetValue(p,ks); if(nv) CFNumberGetValue(nv,kCFNumberSInt64Type,&tel[k]); CFRelease(ks);} }
      if(p) CFRelease(p); }
    double c3=tcpu();
    uint64_t tp=0; notify_get_state(ntok,&tp);
    double dt = t - tPrev; tPrev=t;
    fprintf(fo,"%.3f,%.3f,%.3f,%.2f,%.3f,%.3f,%llu",t,first?0:dt,(c1-c0)*1e3,(w1-w0)*1e3,(c2-c1)*1e3,(c3-c2)*1e3,tp);
    for(int i=0;i<nk;i++) fprintf(fo,",%.4f",pv[i]);
    fprintf(fo,",%lld,%.4f,%d,%lld,%lld,%lld,%lld,%lld", agx, (agxPrev<0||agx<0||dt<=0)?NAN:(agx-agxPrev)/1e9/dt, nchg, cpu,gpu0,ane,dram,ave);
    for(int k=0;telKeys[k];k++) fprintf(fo,",%lld",tel[k]);
    fprintf(fo,"\n");
    if(n%10==0) fflush(fo);
    agxPrev=agx; first=0; n++;
  }
  struct rusage_info_v6 ru; proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t*)&ru);
  fprintf(stderr,"ptlog done: %ld samples, own energy %.3f J\n", n, ru.ri_energy_nj/1e9);
  fclose(fo); fclose(fp); return 0;
}
