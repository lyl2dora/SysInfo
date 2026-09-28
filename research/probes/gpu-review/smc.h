// READ-ONLY AppleSMC access: only selectors 9 (GetKeyInfo), 5 (ReadKey), 8 (GetKeyFromIndex). No writes.
#include <IOKit/IOKitLib.h>
#include <string.h>
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t smc_conn;
static uint32_t k4(const char *s){ return (uint32_t)s[0]<<24|(uint32_t)s[1]<<16|(uint32_t)s[2]<<8|(uint32_t)s[3]; }
static void s4(uint32_t k,char*o){ o[0]=k>>24;o[1]=k>>16;o[2]=k>>8;o[3]=k;o[4]=0; }
static int smc_open(void){ io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC")); if(!s) return -1; kern_return_t r=IOServiceOpen(s,mach_task_self(),0,&smc_conn); IOObjectRelease(s); return r==KERN_SUCCESS?0:-2; }
static kern_return_t smc_call(SMCParam*in,SMCParam*out){ size_t sz=sizeof(SMCParam); return IOConnectCallStructMethod(smc_conn,2,in,sizeof(SMCParam),out,&sz); }
static int smc_read(uint32_t key, char type[5], uint8_t *bytes, uint32_t *size){
  SMCParam in={0},out={0}; in.key=key; in.data8=9;
  if(smc_call(&in,&out)!=KERN_SUCCESS||out.result!=0) return -1;
  s4(out.keyInfo.dataType,type); *size=out.keyInfo.dataSize;
  in.keyInfo.dataSize=out.keyInfo.dataSize; in.data8=5; memset(&out,0,sizeof out);
  if(smc_call(&in,&out)!=KERN_SUCCESS||out.result!=0) return -2;
  memcpy(bytes,out.bytes,32); return 0; }
static double smc_val(const char*key){ char t[5]; uint8_t b[32]; uint32_t sz; if(smc_read(k4(key),t,b,&sz)) return -999;
  if(!strcmp(t,"flt ")){ float f; memcpy(&f,b,4); return f; }
  if(!strcmp(t,"sp78")) return (int16_t)(b[0]<<8|b[1])/256.0;
  if(!strcmp(t,"ui8 ")) return b[0]; if(!strcmp(t,"ui16")) return b[0]<<8|b[1];
  if(!strcmp(t,"ui32")) return (double)((uint32_t)b[0]<<24|b[1]<<16|b[2]<<8|b[3]);
  return -998; }
static int smc_count(void){ char t[5]; uint8_t b[32]; uint32_t sz; if(smc_read(k4("#KEY"),t,b,&sz)) return 0; return (uint32_t)b[0]<<24|b[1]<<16|b[2]<<8|b[3]; }
static int smc_key_at(int i, char name[5]){ SMCParam in={0},out={0}; in.data8=8; in.data32=i; if(smc_call(&in,&out)!=KERN_SUCCESS) return -1; s4(out.key,name); return 0; }
