// Review probe (READ-ONLY SMC): find Tp*/Tm*/Ts* flt keys whose values are bit-identical across 5 reads (1 s apart, light Super load
// in reads 3-5 so values move) => aliases of the same physical sensor.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
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
static uint32_t keys[512], sz[512]; static int nk=0; static float v[512][5];
static atomic_int stop_flag=0; static void* spin(void* a){ pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED,0); volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
int main(){
  IOServiceOpen(IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")), mach_task_self(), 0, &conn);
  SMCParam in={0}, out={0}; in.key=('#'<<24)|('K'<<16)|('E'<<8)|'Y'; in.data8=9; call(&in,&out); in.keyInfo.dataSize=out.keyInfo.dataSize; in.data8=5; call(&in,&out);
  uint32_t total=(out.bytes[0]<<24)|(out.bytes[1]<<16)|(out.bytes[2]<<8)|out.bytes[3];
  for(uint32_t i=0;i<total&&nk<512;i++){ SMCParam a={0},b={0}; a.data8=8; a.data32=i; if(call(&a,&b)||b.result) continue; char c0=b.key>>24, c1=b.key>>16; if(c0!='T'||(c1!='p'&&c1!='m'&&c1!='s')) continue;
    SMCParam c={0},d={0}; c.key=b.key; c.data8=9; if(call(&c,&d)||d.result) continue; if(d.keyInfo.dataType!=(('f'<<24)|('l'<<16)|('t'<<8)|' ')) continue; keys[nk]=b.key; sz[nk]=d.keyInfo.dataSize; nk++; }
  pthread_t th[18];
  for(int r=0;r<5;r++){ if(r==2) for(int j=0;j<18;j++) pthread_create(&th[j],NULL,spin,NULL);
    for(int i=0;i<nk;i++){ SMCParam a={0},b={0}; a.key=keys[i]; a.keyInfo.dataSize=sz[i]; a.data8=5; call(&a,&b); memcpy(&v[i][r],b.bytes,4); } sleep(1); }
  atomic_store(&stop_flag,1); for(int j=0;j<18;j++) pthread_join(th[j],NULL);
  printf("Tp/Tm/Ts flt keys: %d. Groups of bit-identical keys over 5 reads:\n", nk); int used[512]={0}, groups=0;
  for(int i=0;i<nk;i++){ if(used[i]) continue; int any=0; for(int j=i+1;j<nk;j++) if(!memcmp(v[i],v[j],sizeof v[i])){ if(!any){ printf("  %c%c%c%c", keys[i]>>24,keys[i]>>16,keys[i]>>8,keys[i]); any=1; groups++; } printf(" = %c%c%c%c", keys[j]>>24,keys[j]>>16,keys[j]>>8,keys[j]); used[j]=1; } if(any) printf("  (last %.2f)\n", v[i][4]); }
  printf("alias groups: %d\n", groups); return 0;
}
