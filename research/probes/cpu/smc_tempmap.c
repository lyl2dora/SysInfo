// Probe (READ-ONLY SMC): which SMC temperature keys track the Super cluster vs the M ("Performance") cluster.
// Loads 6 threads at QOS_CLASS_USER_INTERACTIVE (-> Super cores cpu12-17) then 6 at QOS_CLASS_BACKGROUND (-> M cluster 0, cpu0-5),
// and reports per-key temperature rise vs baseline. No SMC writes.
#include <IOKit/IOKitLib.h>
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
static uint32_t keys[512]; static int nkeys=0; static uint32_t sizes[512];
static double readf(int i){ SMCParam in={0}, out={0}; in.key=keys[i]; in.keyInfo.dataSize=sizes[i]; in.data8=5; if(call(&in,&out)||out.result) return -1; float f; memcpy(&f,out.bytes,4); return f; }
static atomic_int stop_flag=0; static qos_class_t gq;
static void* spin(void* a){ pthread_set_qos_class_self_np(gq,0); volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
static void snapshot(double* v){ for(int i=0;i<nkeys;i++) v[i]=readf(i); }
static void phase(const char* name, qos_class_t q, double* base, double* after){
  snapshot(base); gq=q; atomic_store(&stop_flag,0); pthread_t th[6]; for(int i=0;i<6;i++) pthread_create(&th[i],NULL,spin,NULL);
  sleep(8); snapshot(after); atomic_store(&stop_flag,1); for(int i=0;i<6;i++) pthread_join(th[i],NULL);
  printf("\n== %s: keys sorted by rise ==\n", name);
  int idx[512]; for(int i=0;i<nkeys;i++) idx[i]=i;
  for(int i=0;i<nkeys;i++) for(int j=i+1;j<nkeys;j++) if(after[idx[j]]-base[idx[j]] > after[idx[i]]-base[idx[i]]){ int t=idx[i]; idx[i]=idx[j]; idx[j]=t; }
  for(int i=0;i<nkeys;i++){ char k[5]={keys[idx[i]]>>24,keys[idx[i]]>>16,keys[idx[i]]>>8,keys[idx[i]],0}; printf(" %s:%+.1f(%.1f)", k, after[idx[i]]-base[idx[i]], after[idx[i]]); if(i%8==7) printf("\n"); }
  printf("\n");
}
int main(){
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")); IOServiceOpen(svc, mach_task_self(), 0, &conn);
  SMCParam in={0}, out={0}; in.key=('#'<<24)|('K'<<16)|('E'<<8)|'Y'; in.data8=9; call(&in,&out); in.keyInfo.dataSize=out.keyInfo.dataSize; in.data8=5; call(&in,&out);
  uint32_t total=(out.bytes[0]<<24)|(out.bytes[1]<<16)|(out.bytes[2]<<8)|out.bytes[3];
  for(uint32_t i=0;i<total && nkeys<512;i++){ SMCParam a={0}, b={0}; a.data8=8; a.data32=i; if(call(&a,&b)||b.result) continue; uint32_t k=b.key; char c0=k>>24;
    if(c0!='T') continue; SMCParam c={0}, d={0}; c.key=k; c.data8=9; if(call(&c,&d)||d.result) continue; if(d.keyInfo.dataType!=(('f'<<24)|('l'<<16)|('t'<<8)|' ')) continue;
    keys[nkeys]=k; sizes[nkeys]=d.keyInfo.dataSize; nkeys++; }
  printf("flt temperature keys: %d\n", nkeys);
  static double b1[512], a1[512], b2[512], a2[512];
  phase("6 threads QOS_CLASS_USER_INTERACTIVE (Super cluster)", QOS_CLASS_USER_INTERACTIVE, b1, a1);
  sleep(20);
  phase("6 threads QOS_CLASS_BACKGROUND (M cluster 0)", QOS_CLASS_BACKGROUND, b2, a2);
  IOServiceClose(conn); return 0;
}
