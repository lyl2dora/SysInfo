// tp_watch.c — 温度/功耗/热状态联合记录器（只读 SMC + IOReport Energy Model + 每核 tick + 热状态），可选内置分阶段 CPU 负载。
// 用法：tp_watch <out.csv> <阶段表>
//   阶段表形如 "idle:10,bg4:15,idle:10,ui4:15,idle:10"；bgN = N 个 QOS_CLASS_BACKGROUND 自旋线程，uiN = N 个 USER_INTERACTIVE 线程，
//   dfN = N 个 DEFAULT QoS 线程，utN = N 个 UTILITY QoS 线程。线程只在本进程内，阶段结束即 join；负载总时长由调用者保证 ≤60 s。
// 每秒（对齐到整秒）写一行：墙钟、阶段、每簇 CPU 占用（按 IODeviceTree cluster-id 分组）、ProcessInfo 等价的 thermalState
// （notify com.apple.system.thermalpressurelevel）、Energy Model 若干 CPU/GPU 通道的 1 s 增量（W）、Energy Model 本秒有变化的通道数、
// 以及全部 T*/P*/I*/V*/R* 前缀（环境变量 TPW_PREFIX 可缩小首字母集合，如 "PR"）、类型 flt/ioft 的 SMC 键数值。另在 stderr 打印每次采样的线程 CPU 开销（SMC 批读、EM 采样）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <notify.h>
#include "smc_ro.h"
#include "ioreport.h"

#define MAXK 1400
static SMCKeyMeta keys[MAXK]; static int nk=0;
static int ncpu=0, cluster_of[64], nclusters=0, cluster_ids[16];
static atomic_int stop_flag=0; static qos_class_t gq;
static void* spin(void* a){ (void)a; pthread_set_qos_class_self_np(gq,0); volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }

static void load_topology(void){
  io_registry_entry_t cpus=IORegistryEntryFromPath(kIOMainPortDefault,"IODeviceTree:/cpus"); io_iterator_t it; IORegistryEntryGetChildIterator(cpus,kIODeviceTreePlane,&it);
  io_registry_entry_t c; while((c=IOIteratorNext(it))){ io_name_t nm; IORegistryEntryGetName(c,nm); if(!strncmp(nm,"cpu",3)){ int idx=atoi(nm+3);
      CFDataRef d=IORegistryEntryCreateCFProperty(c,CFSTR("cluster-id"),kCFAllocatorDefault,0); uint32_t cid=99; if(d){ CFDataGetBytes(d,CFRangeMake(0,4),(UInt8*)&cid); CFRelease(d);}
      if(idx<64){ cluster_of[idx]=(int)cid; if(idx+1>ncpu) ncpu=idx+1; int found=0; for(int i=0;i<nclusters;i++) if(cluster_ids[i]==(int)cid) found=1; if(!found) cluster_ids[nclusters++]=(int)cid; } }
    IOObjectRelease(c);} IOObjectRelease(it); IOObjectRelease(cpus);
  for(int i=0;i<nclusters;i++) for(int j=i+1;j<nclusters;j++) if(cluster_ids[j]<cluster_ids[i]){ int t=cluster_ids[i]; cluster_ids[i]=cluster_ids[j]; cluster_ids[j]=t; } }

static uint64_t prev_ticks[64][4];
static void cluster_util(double *out){ // 每簇平均占用 0..1
  processor_info_array_t info; mach_msg_type_number_t cnt; natural_t n;
  if(host_processor_info(mach_host_self(),PROCESSOR_CPU_LOAD_INFO,&n,&info,&cnt)) return;
  double busy[16]={0}, tot[16]={0};
  for(natural_t i=0;i<n && i<64;i++){ uint64_t t[4]; for(int s=0;s<4;s++) t[s]=(uint32_t)info[i*CPU_STATE_MAX+s];
    uint64_t d[4]; for(int s=0;s<4;s++){ d[s]=t[s]-prev_ticks[i][s]; prev_ticks[i][s]=t[s]; }
    int ci=0; for(int k=0;k<nclusters;k++) if(cluster_ids[k]==cluster_of[i]) ci=k;
    busy[ci]+=d[CPU_STATE_USER]+d[CPU_STATE_SYSTEM]+d[CPU_STATE_NICE]; tot[ci]+=d[0]+d[1]+d[2]+d[3]; }
  vm_deallocate(mach_task_self(),(vm_address_t)info,cnt*sizeof(int));
  for(int k=0;k<nclusters;k++) out[k]= tot[k]>0? busy[k]/tot[k] : 0; }

static const char* em_names[]={"CPU Energy","EACC_CPU","PACC0_CPU","PACC1_CPU","PCPU","MCPU0","MCPU1","PCPM","MCPM0","MCPM1","GPU0","GPU Energy","DRAM0","ANE0",NULL};
#define NEM 14

int main(int argc,char**argv){
  if(argc<3){ fprintf(stderr,"usage: tp_watch out.csv phases\n"); return 2; }
  if(smc_open()){ fprintf(stderr,"smc open fail\n"); return 1; }
  load_topology(); fprintf(stderr,"ncpu=%d clusters=%d\n",ncpu,nclusters);
  int n=smc_count();
  for(int i=0;i<n && nk<MAXK;i++){ uint32_t k; if(smc_key_at(i,&k)) continue; char c0=(char)(k>>24); const char* pf=getenv("TPW_PREFIX"); if(!strchr(pf?pf:"TPIVR",c0)) continue;
    SMCKeyMeta m; if(smc_keyinfo(k,&m)) continue; char t[5]; s4(m.type,t); if(strcmp(t,"flt ") && strcmp(t,"ioft")) continue; uint8_t b[32]; if(smc_read_raw(&m,b)) continue; keys[nk++]=m; }
  fprintf(stderr,"smc T/P/I/V flt|ioft keys=%d\n",nk);
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0); CFMutableDictionaryRef subbed=NULL;
  IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&subbed,0,NULL); CFDictionaryRef prevS=IOReportCreateSamples(sub,subbed,NULL);
  int tok; notify_register_check("com.apple.system.thermalpressurelevel",&tok);
  FILE*fo=fopen(argv[1],"w"); fprintf(fo,"t,phase");
  for(int k=0;k<nclusters;k++) fprintf(fo,",util_c%d",cluster_ids[k]);
  fprintf(fo,",thermpress,em_changed"); for(int e=0;em_names[e];e++) fprintf(fo,",EM:%s",em_names[e]);
  for(int i=0;i<nk;i++){ char kn[5]; s4(keys[i].key,kn); fprintf(fo,",%s",kn);} fprintf(fo,"\n");
  double tmp[16]; cluster_util(tmp);
  // 解析阶段
  char *spec=strdup(argv[2]); char *save=NULL; double next=floor(wall_s())+1; double prevT=wall_s();
  double smc_cost_sum=0, em_cost_sum=0; int ns=0; double smc_costs[4000], em_costs[4000];
  for(char*tok2=strtok_r(spec,",",&save);tok2;tok2=strtok_r(NULL,",",&save)){
    char name[32]; int secs; if(sscanf(tok2,"%31[^:]:%d",name,&secs)!=2) continue; int nth=0; pthread_t th[64];
    if(!strncmp(name,"bg",2)){ gq=QOS_CLASS_BACKGROUND; nth=atoi(name+2);} else if(!strncmp(name,"ui",2)){ gq=QOS_CLASS_USER_INTERACTIVE; nth=atoi(name+2);} else if(!strncmp(name,"df",2)){ gq=QOS_CLASS_DEFAULT; nth=atoi(name+2);} else if(!strncmp(name,"ut",2)){ gq=QOS_CLASS_UTILITY; nth=atoi(name+2);}
    atomic_store(&stop_flag,0); for(int i=0;i<nth;i++) pthread_create(&th[i],NULL,spin,NULL);
    fprintf(stderr,"phase %s %ds threads=%d\n",name,secs,nth);
    for(int s=0;s<secs;s++){
      double now=wall_s(); if(now<next) usleep((useconds_t)((next-now)*1e6)); next+=1;
      double t=wall_s(); double u[16]; cluster_util(u);
      uint64_t st=0; notify_get_state(tok,&st);
      double c0=thread_cpu_ms(); CFDictionaryRef cur=IOReportCreateSamples(sub,subbed,NULL); CFDictionaryRef dl=IOReportCreateSamplesDelta(prevS,cur,NULL);
      double emv[NEM]; for(int e=0;e<NEM;e++) emv[e]=NAN; int changed=0; double dt=t-prevT; prevT=t;
      CFArrayRef arr=CFDictionaryGetValue(dl,CFSTR("IOReportChannels"));
      for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); int64_t v=IOReportSimpleGetIntegerValue(c,NULL); if(v!=0) changed++;
        char nm[64],un[16]; cfstr(IOReportChannelGetChannelName(c),nm,64); cfstr(IOReportChannelGetUnitLabel(c),un,16);
        double scale= !strcmp(un,"mJ")?1e-3 : !strcmp(un,"uJ")?1e-6 : !strcmp(un,"nJ")?1e-9 : 0;
        for(int e=0;em_names[e];e++) if(!strcmp(nm,em_names[e])) emv[e]=v*scale/dt; }
      CFRelease(dl); CFRelease(prevS); prevS=cur; double c1=thread_cpu_ms();
      double vals[MAXK]; for(int i=0;i<nk;i++){ uint8_t b[32]; vals[i]=NAN; if(!smc_read_raw(&keys[i],b)) smc_decode(&keys[i],b,&vals[i]); }
      double c2=thread_cpu_ms(); if(ns<4000){ em_costs[ns]=c1-c0; smc_costs[ns]=c2-c1; ns++; } em_cost_sum+=c1-c0; smc_cost_sum+=c2-c1;
      fprintf(fo,"%.3f,%s",t,name); for(int k=0;k<nclusters;k++) fprintf(fo,",%.3f",u[k]); fprintf(fo,",%llu,%d",st,changed);
      for(int e=0;e<NEM;e++) fprintf(fo,",%.4f",emv[e]); for(int i=0;i<nk;i++) fprintf(fo,",%.4f",vals[i]); fprintf(fo,"\n"); fflush(fo);
    }
    atomic_store(&stop_flag,1); for(int i=0;i<nth;i++) pthread_join(th[i],NULL);
  }
  fclose(fo);
  fprintf(stderr,"samples=%d  mean per-sample thread CPU: EM sample+delta %.3f ms, SMC %d keys %.3f ms (%.4f ms/key)\n",ns,em_cost_sum/ns,nk,smc_cost_sum/ns,smc_cost_sum/ns/nk);
  return 0; }
