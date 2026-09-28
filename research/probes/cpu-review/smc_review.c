// Review probe (READ-ONLY SMC, selector 2, cmds 9/5/8 only): (1) group temperature keys Tp**, Tm0*, Tm1*, Tm2*, Ts** and report
// group averages; (2) enumerate ALL flt keys whose name starts with 'P' (power) and show which move with CPU load;
// phases: idle, 6x USER_INTERACTIVE (Super), 18x USER_INITIATED (all), 12x UTILITY. Also samples per-core busy% (host_processor_info)
// during each phase so the core placement is known.
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
typedef struct { char major, minor, build, reserved[1]; uint16_t release; } Vers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } KeyInfo;
typedef struct { uint32_t key; Vers vers; PLimit pLimitData; KeyInfo keyInfo; char result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t conn;
static int call(SMCParam* in, SMCParam* out){ size_t o=sizeof(SMCParam); return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCParam), out, &o); }
#define MAXK 1024
static uint32_t keys[MAXK], sizes[MAXK]; static int nk=0;
static double rd(int i){ SMCParam in={0}, out={0}; in.key=keys[i]; in.keyInfo.dataSize=sizes[i]; in.data8=5; if(call(&in,&out)||out.result) return -999; float f; memcpy(&f,out.bytes,4); return f; }
static void kn(uint32_t k, char* s){ s[0]=k>>24; s[1]=k>>16; s[2]=k>>8; s[3]=k; s[4]=0; }
static atomic_int stop_flag=0; static qos_class_t gq;
static void* spin(void* a){ pthread_set_qos_class_self_np(gq,0); volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
static void ticks(unsigned* busy, unsigned* tot){ natural_t n; processor_info_array_t info; mach_msg_type_number_t c; host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &c);
  for(unsigned i=0;i<n;i++){ unsigned* t=(unsigned*)&info[i*CPU_STATE_MAX]; busy[i]=t[CPU_STATE_USER]+t[CPU_STATE_SYSTEM]+t[CPU_STATE_NICE]; tot[i]=busy[i]+t[CPU_STATE_IDLE]; }
  vm_deallocate(mach_task_self(),(vm_address_t)info,c*sizeof(integer_t)); }
static int grp(const char* k){ if(k[0]!='T') return -1; if(k[1]=='p'&&k[2]=='0') return 0; if(k[1]=='p'&&k[2]=='1') return 1; if(k[1]=='m'&&k[2]=='0') return 2; if(k[1]=='m'&&k[2]=='1') return 3; if(k[1]=='m'&&k[2]=='2') return 4; if(k[1]=='s') return 5; return -1; }
static const char* gname[]={"Tp0*","Tp1*","Tm0*","Tm1*","Tm2*","Ts0*"};
static void groupavg(double* v, double* avg, int* cnt){ for(int g=0;g<6;g++){avg[g]=0;cnt[g]=0;} for(int i=0;i<nk;i++){ char s[5]; kn(keys[i],s); int g=grp(s); if(g<0||v[i]<-100||v[i]>150) continue; avg[g]+=v[i]; cnt[g]++; } for(int g=0;g<6;g++) if(cnt[g]) avg[g]/=cnt[g]; }
static void phase(const char* name, qos_class_t q, int nth, int secs){
  static double b[MAXK], a[MAXK]; unsigned b0[64],t0[64],b1[64],t1[64];
  for(int i=0;i<nk;i++) b[i]=rd(i); ticks(b0,t0);
  gq=q; atomic_store(&stop_flag,0); pthread_t th[64]; for(int i=0;i<nth;i++) pthread_create(&th[i],NULL,spin,NULL);
  sleep(secs); ticks(b1,t1); for(int i=0;i<nk;i++) a[i]=rd(i);
  atomic_store(&stop_flag,1); for(int i=0;i<nth;i++) pthread_join(th[i],NULL);
  printf("\n== %s (%ds) ==\n per-core busy%%:", name, secs); for(int i=0;i<18;i++) printf(" %d:%u", i, (t1[i]-t0[i])? 100*(b1[i]-b0[i])/(t1[i]-t0[i]) : 0); printf("\n");
  double ga[6], gb[6]; int gc[6]; groupavg(b,gb,gc); groupavg(a,ga,gc);
  for(int g=0;g<6;g++) printf("  %s n=%d avg %.1f -> %.1f (rise %+.1f)\n", gname[g], gc[g], gb[g], ga[g], ga[g]-gb[g]);
  printf("  P* power keys (flt) before -> after:\n");
  for(int i=0;i<nk;i++){ char s[5]; kn(keys[i],s); if(s[0]!='P') continue; if(b[i]==0 && a[i]==0) continue; printf("   %s %.3f -> %.3f (%+.3f)\n", s, b[i], a[i], a[i]-b[i]); }
}
int main(){
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")); if(IOServiceOpen(svc, mach_task_self(), 0, &conn)) return 1;
  SMCParam in={0}, out={0}; in.key=('#'<<24)|('K'<<16)|('E'<<8)|'Y'; in.data8=9; call(&in,&out); in.keyInfo.dataSize=out.keyInfo.dataSize; in.data8=5; call(&in,&out);
  uint32_t total=(out.bytes[0]<<24)|(out.bytes[1]<<16)|(out.bytes[2]<<8)|out.bytes[3]; printf("#KEY=%u\n", total);
  for(uint32_t i=0;i<total && nk<MAXK;i++){ SMCParam a={0}, b={0}; a.data8=8; a.data32=i; if(call(&a,&b)||b.result) continue; uint32_t k=b.key; char c0=k>>24;
    if(c0!='T' && c0!='P') continue; SMCParam c={0}, d={0}; c.key=k; c.data8=9; if(call(&c,&d)||d.result) continue; if(d.keyInfo.dataType!=(('f'<<24)|('l'<<16)|('t'<<8)|' ')) continue;
    keys[nk]=k; sizes[nk]=d.keyInfo.dataSize; nk++; }
  int np=0, nt=0, g[6]={0}; for(int i=0;i<nk;i++){ char s[5]; kn(keys[i],s); if(s[0]=='P') np++; else nt++; int gg=grp(s); if(gg>=0) g[gg]++; }
  printf("flt keys: T*=%d P*=%d; Tp0*=%d Tp1*=%d Tm0*=%d Tm1*=%d Tm2*=%d Ts0*=%d\n", nt, np, g[0],g[1],g[2],g[3],g[4],g[5]);
  printf("Tm keys:"); for(int i=0;i<nk;i++){ char s[5]; kn(keys[i],s); if(s[0]=='T'&&s[1]=='m') printf(" %s",s);} printf("\n");
  printf("Tp keys:"); for(int i=0;i<nk;i++){ char s[5]; kn(keys[i],s); if(s[0]=='T'&&s[1]=='p') printf(" %s",s);} printf("\n");
  phase("6x USER_INTERACTIVE", QOS_CLASS_USER_INTERACTIVE, 6, 8); sleep(30);
  phase("12x UTILITY", QOS_CLASS_UTILITY, 12, 8); sleep(30);
  phase("18x USER_INITIATED", QOS_CLASS_USER_INITIATED, 18, 8);
  IOServiceClose(conn); return 0;
}
