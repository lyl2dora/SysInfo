// Probe (READ-ONLY): Stats CPU TemperatureReader keys via AppleSMC user client (selector 2; cmds 5=read, 9=keyinfo, 8=key-by-index).
// Never writes. Checks TC0D/E/F/P/H and the M5 Tp list from Modules/CPU/readers.swift:269-270, and enumerates all Tp*/Te*/Tf*/PC*/PS* keys.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
static atomic_int stop_flag=0; static void* spin(void* a){ volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
typedef struct { char major, minor, build, reserved[1]; uint16_t release; } Vers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } KeyInfo;
typedef struct { uint32_t key; Vers vers; PLimit pLimitData; KeyInfo keyInfo; char result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t conn;
static uint32_t k2u(const char* s){ return (s[0]<<24)|(s[1]<<16)|(s[2]<<8)|s[3]; }
static void u2k(uint32_t u, char* s){ s[0]=u>>24; s[1]=u>>16; s[2]=u>>8; s[3]=u; s[4]=0; }
static int call(SMCParam* in, SMCParam* out){ size_t o=sizeof(SMCParam); return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCParam), out, &o); }
static int readKey(const char* key, double* val, char* type){
  SMCParam in={0}, out={0}; in.key=k2u(key); in.data8=9;
  if(call(&in,&out) || out.result) return -1;
  uint32_t sz=out.keyInfo.dataSize, ty=out.keyInfo.dataType; u2k(ty,type);
  memset(&in,0,sizeof in); in.key=k2u(key); in.keyInfo.dataSize=sz; in.data8=5;
  if(call(&in,&out) || out.result) return -2;
  if(!strcmp(type,"flt ") && sz==4){ float f; memcpy(&f,out.bytes,4); *val=f; }
  else if(!strcmp(type,"sp78")){ int16_t v=(out.bytes[0]<<8)|out.bytes[1]; *val=v/256.0; }
  else if(!strcmp(type,"ui8 ")) *val=out.bytes[0];
  else if(!strcmp(type,"ui16")) *val=(out.bytes[0]<<8)|out.bytes[1];
  else if(!strcmp(type,"ui32")) *val=(uint32_t)((out.bytes[0]<<24)|(out.bytes[1]<<16)|(out.bytes[2]<<8)|out.bytes[3]);
  else *val=-99999;
  return 0;
}
int main(){
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
  if(!svc){ printf("AppleSMC not found\n"); return 1; }
  kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn); printf("IOServiceOpen AppleSMC kr=0x%x\n", kr); if(kr) return 1;
  const char* legacy[]={"TC0D","TC0E","TC0F","TC0P","TC0H",NULL};
  const char* m5[]={"Tp00","Tp04","Tp08","Tp0C","Tp0G","Tp0K","Tp0O","Tp0R","Tp0U","Tp0X","Tp0a","Tp0d","Tp0g","Tp0j","Tp0m","Tp0p","Tp0u","Tp0y",NULL};
  double v; char t[5];
  printf("Legacy Intel keys (Stats tries first):"); for(int i=0;legacy[i];i++){ int r=readKey(legacy[i],&v,t); if(r) printf(" %s=ABSENT", legacy[i]); else printf(" %s=%.2f(%s)", legacy[i], v, t);} printf("\n");
  pthread_t th[18]; int load=getenv("LOAD")!=NULL; if(load){ for(int i=0;i<18;i++) pthread_create(&th[i],NULL,spin,NULL); printf("LOAD: 18 spinning threads started\n"); }
  for(int pass=0; pass<(load?6:2); pass++){
    double sum=0; int n=0; printf("Stats M5 list pass %d:", pass);
    for(int i=0;m5[i];i++){ int r=readKey(m5[i],&v,t); if(r) printf(" %s=ABSENT", m5[i]); else { printf(" %s=%.1f", m5[i], v); sum+=v; n++; } }
    printf("\n  -> Stats average over %d present keys = %.2f C\n", n, n? sum/n:0); sleep(1);
  }
  if(load){ atomic_store(&stop_flag,1); for(int i=0;i<18;i++) pthread_join(th[i],NULL); return 0; }
  // enumerate count
  double cnt; readKey("#KEY",&cnt,t); printf("#KEY=%.0f\n", cnt);
  printf("All Tp*/Te*/Tf*/TC*/Ts* and PC*/PP*/PS* keys present:\n");
  for(uint32_t i=0;i<(uint32_t)cnt;i++){
    SMCParam in={0}, out={0}; in.data8=8; in.data32=i; if(call(&in,&out)||out.result) continue;
    char k[5]; u2k(out.key,k);
    if((k[0]=='T' && (k[1]=='p'||k[1]=='e'||k[1]=='f'||k[1]=='C'||k[1]=='s')) || (k[0]=='P' && (k[1]=='C'||k[1]=='P'||k[1]=='S'))){
      if(readKey(k,&v,t)==0) printf("  %s %s %.3f\n", k, t, v); else printf("  %s (read fail)\n", k);
    }
  }
  IOServiceClose(conn); return 0;
}
