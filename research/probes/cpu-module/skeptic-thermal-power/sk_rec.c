// sk_rec.c — skeptic-thermal-power 的记录器 + 分阶段 QoS 负载（只读 SMC；负载线程只在本进程内）。
// 用法：sk_rec <out.csv> <采样Hz> <键前缀表,逗号分隔> <阶段表>
//   阶段表如 "idle:8,ui6:10,idle:8"；uiN/dfN/utN/bgN = N 个 USER_INTERACTIVE/DEFAULT/UTILITY/BACKGROUND 自旋线程；负载总时长由调用者保证 ≤60 s。
// 每个采样写一行：epoch、阶段、每簇占用（IODeviceTree cluster-id，host_processor_info 每核 tick 差分）、每个键的数值。
// stderr：每次 SMC 批读的线程 CPU 与墙钟耗时中位数。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include "sk_smc.h"
static int ncpu=0, clu[128], ncl=0, clid[16];
static void topo(void){ io_registry_entry_t cpus=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/cpus"); io_iterator_t it; IORegistryEntryGetChildIterator(cpus,kIODeviceTreePlane,&it);
  io_registry_entry_t c; while((c=IOIteratorNext(it))){ CFTypeRef lid=IORegistryEntryCreateCFProperty(c,CFSTR("logical-cpu-id"),kCFAllocatorDefault,0); CFDataRef cd=IORegistryEntryCreateCFProperty(c,CFSTR("cluster-id"),kCFAllocatorDefault,0);
    if(lid&&cd){ int l=-1; if(CFGetTypeID(lid)==CFNumberGetTypeID()) CFNumberGetValue(lid,kCFNumberIntType,&l); else { uint32_t x=0; CFDataGetBytes((CFDataRef)lid,CFRangeMake(0,4),(UInt8*)&x); l=(int)x; }
      uint32_t id=0; CFDataGetBytes(cd,CFRangeMake(0,4),(UInt8*)&id); if(l>=0&&l<128){ clu[l]=(int)id; if(l+1>ncpu) ncpu=l+1; int f=0; for(int i=0;i<ncl;i++) if(clid[i]==(int)id) f=1; if(!f) clid[ncl++]=(int)id; } }
    if(lid) CFRelease(lid); if(cd) CFRelease(cd); IOObjectRelease(c); }
  IOObjectRelease(it); IOObjectRelease(cpus);
  for(int i=0;i<ncl;i++) for(int j=i+1;j<ncl;j++) if(clid[j]<clid[i]){ int t=clid[i]; clid[i]=clid[j]; clid[j]=t; } }
static uint32_t prevt[128][4];
static void util(double*o){ processor_info_array_t info; mach_msg_type_number_t cnt; natural_t n; if(host_processor_info(mach_host_self(),PROCESSOR_CPU_LOAD_INFO,&n,&info,&cnt)) return;
  double busy[16]={0},tot[16]={0}; for(natural_t i=0;i<n&&i<128;i++){ uint32_t d[4]; for(int s=0;s<4;s++){ uint32_t t=(uint32_t)info[i*CPU_STATE_MAX+s]; d[s]=t-prevt[i][s]; prevt[i][s]=t; }
    int ci=0; for(int k=0;k<ncl;k++) if(clid[k]==clu[i]) ci=k; busy[ci]+=d[0]+d[1]+d[3]; tot[ci]+=d[0]+d[1]+d[2]+d[3]; }
  vm_deallocate(mach_task_self(),(vm_address_t)info,cnt*sizeof(int)); for(int k=0;k<ncl;k++) o[k]=tot[k]>0?busy[k]/tot[k]:NAN; }
static atomic_int stopf; static qos_class_t gq;
static void* spin(void*a){ (void)a; pthread_set_qos_class_self_np(gq,0); volatile uint64_t x=88172645463325252ULL; volatile double y=1.0;
  while(!atomic_load_explicit(&stopf,memory_order_relaxed)){ for(int i=0;i<4096;i++){ x^=x<<13; x^=x>>7; x^=x<<17; y=y*0.9999999+1e-7; } } return NULL; }
static int cmpd(const void*a,const void*b){ double x=*(const double*)a,y=*(const double*)b; return x<y?-1:x>y; }
#define MAXK 800
static SkKey K[MAXK]; static int nk;
int main(int argc,char**argv){
  if(argc<5){ fprintf(stderr,"usage: sk_rec out.csv hz prefixes phases\n"); return 2; }
  double hz=atof(argv[2]); if(sk_open()){ fprintf(stderr,"smc open failed\n"); return 1; } topo();
  static SkKey all[4096]; int na=sk_enum(all,4096,NULL,0); char pre[512]; strncpy(pre,argv[3],511);
  for(int i=0;i<na&&nk<MAXK;i++){ char tmp[512]; strcpy(tmp,pre); for(char*p=strtok(tmp,",");p;p=strtok(NULL,",")) if(!strncmp(all[i].name,p,strlen(p))){ uint8_t b[32]; double v; if(!sk_raw(&all[i],b)&&!sk_val(&all[i],b,&v)) K[nk++]=all[i]; break; } }
  fprintf(stderr,"ncpu=%d clusters=%d keys=%d/%d\n",ncpu,ncl,nk,na);
  FILE*fo=fopen(argv[1],"w"); fprintf(fo,"t,phase"); for(int k=0;k<ncl;k++) fprintf(fo,",util_c%d",clid[k]); for(int i=0;i<nk;i++) fprintf(fo,",%s",K[i].name); fprintf(fo,"\n");
  double u[16]; util(u); double per=1.0/hz; double next=sk_wall()+per; static double cc[100000], cw[100000]; int ns=0;
  char*spec=strdup(argv[4]); char*sv=NULL;
  for(char*tok=strtok_r(spec,",",&sv);tok;tok=strtok_r(NULL,",",&sv)){ char nm[32]; int secs; if(sscanf(tok,"%31[^:]:%d",nm,&secs)!=2) continue; int nth=0; pthread_t th[64];
    if(!strncmp(nm,"ui",2)){gq=QOS_CLASS_USER_INTERACTIVE;nth=atoi(nm+2);} else if(!strncmp(nm,"df",2)){gq=QOS_CLASS_DEFAULT;nth=atoi(nm+2);} else if(!strncmp(nm,"ut",2)){gq=QOS_CLASS_UTILITY;nth=atoi(nm+2);} else if(!strncmp(nm,"bg",2)){gq=QOS_CLASS_BACKGROUND;nth=atoi(nm+2);}
    atomic_store(&stopf,0); for(int i=0;i<nth&&i<64;i++) pthread_create(&th[i],NULL,spin,NULL);
    int steps=(int)(secs*hz+0.5);
    for(int s=0;s<steps;s++){ double w=sk_wall(); if(w<next) usleep((useconds_t)((next-w)*1e6)); next+=per;
      double te=sk_epoch(); util(u); double c0=sk_tcpu_ms(), w0=sk_wall(); double v[MAXK];
      for(int i=0;i<nk;i++){ uint8_t b[32]; v[i]=NAN; if(!sk_raw(&K[i],b)) sk_val(&K[i],b,&v[i]); }
      double c1=sk_tcpu_ms(), w1=sk_wall(); if(ns<100000){ cc[ns]=c1-c0; cw[ns]=(w1-w0)*1e3; ns++; }
      fprintf(fo,"%.3f,%s",te,nm); for(int k=0;k<ncl;k++) fprintf(fo,",%.3f",u[k]); for(int i=0;i<nk;i++) fprintf(fo,",%.4f",v[i]); fprintf(fo,"\n"); }
    fflush(fo); atomic_store(&stopf,1); for(int i=0;i<nth&&i<64;i++) pthread_join(th[i],NULL); }
  fclose(fo); qsort(cc,ns,sizeof(double),cmpd); qsort(cw,ns,sizeof(double),cmpd);
  fprintf(stderr,"samples=%d SMC batch %d keys: thread CPU median %.3f ms (p10 %.3f p90 %.3f), wall median %.3f ms (p90 %.3f)\n",ns,nk,cc[ns/2],cc[ns/10],cc[ns*9/10],cw[ns/2],cw[ns*9/10]);
  return 0; }
