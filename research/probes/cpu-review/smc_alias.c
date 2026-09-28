// Review probe (READ-ONLY SMC): are Tm0y / Tm2T aliases of the Super sensor Tp0a? Read them (plus neighbours) 6 times, 1 s apart,
// the last 3 reads under 6x USER_INTERACTIVE (Super) load.
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
static double smcf(const char* k){ SMCParam in={0}, out={0}; in.key=(k[0]<<24)|(k[1]<<16)|(k[2]<<8)|k[3]; in.data8=9; if(call(&in,&out)||out.result) return -1;
  uint32_t sz=out.keyInfo.dataSize; memset(&in,0,sizeof in); in.key=(k[0]<<24)|(k[1]<<16)|(k[2]<<8)|k[3]; in.keyInfo.dataSize=sz; in.data8=5; if(call(&in,&out)||out.result) return -2; float f; memcpy(&f,out.bytes,4); return f; }
static atomic_int stop_flag=0; static void* spin(void* a){ pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0); volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
int main(){
  IOServiceOpen(IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")), mach_task_self(), 0, &conn);
  const char* k[]={"Tp0a","Tm0y","Tm2T","Tp0X","Tm0u","Tm2P",NULL}; pthread_t th[6];
  for(int i=0;i<6;i++){ if(i==3) for(int j=0;j<6;j++) pthread_create(&th[j],NULL,spin,NULL);
    printf("%s", i<3?"idle ":"load "); for(int j=0;k[j];j++) printf(" %s=%.4f", k[j], smcf(k[j])); printf("\n"); sleep(1); }
  atomic_store(&stop_flag,1); for(int j=0;j<6;j++) pthread_join(th[j],NULL); return 0;
}
