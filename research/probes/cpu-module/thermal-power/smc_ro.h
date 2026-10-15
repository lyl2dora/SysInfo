// smc_ro.h — 只读 AppleSMC 访问（selector 2 下的 cmd 9=GetKeyInfo、5=ReadKey、8=GetKeyFromIndex），绝不写入。
// 解码：flt / ioft(16.16) / si8/si16/si32/si64 / ui8/ui16/ui32/ui64 / sp78 / fpe2 / flag / hex_；
// 字节序按 dataAttributes 位 0x04 判定（置位 = 小端，调研报告 §1.6），未置位按大端。
#pragma once
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;

static io_connect_t smc_conn;
static inline uint32_t k4(const char *s){ return (uint32_t)(uint8_t)s[0]<<24|(uint32_t)(uint8_t)s[1]<<16|(uint32_t)(uint8_t)s[2]<<8|(uint32_t)(uint8_t)s[3]; }
static inline void s4(uint32_t k,char*o){ o[0]=(char)(k>>24);o[1]=(char)(k>>16);o[2]=(char)(k>>8);o[3]=(char)k;o[4]=0; }
static int smc_open(void){ io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC")); if(!s) return -1; kern_return_t r=IOServiceOpen(s,mach_task_self(),0,&smc_conn); IOObjectRelease(s); return r==KERN_SUCCESS?0:-2; }
static inline kern_return_t smc_call(SMCParam*in,SMCParam*out){ size_t sz=sizeof(SMCParam); return IOConnectCallStructMethod(smc_conn,2,in,sizeof(SMCParam),out,&sz); }

typedef struct { uint32_t key; uint32_t type; uint32_t size; uint8_t attr; } SMCKeyMeta;

static int smc_keyinfo(uint32_t key, SMCKeyMeta *m){
  SMCParam in={0},out={0}; in.key=key; in.data8=9;
  if(smc_call(&in,&out)!=KERN_SUCCESS||out.result!=0) return -1;
  m->key=key; m->type=out.keyInfo.dataType; m->size=out.keyInfo.dataSize; m->attr=out.keyInfo.dataAttributes; return 0; }
// 用缓存的 keyinfo 读原始字节（每次采样只需 1 次 IOConnectCall）
static int smc_read_raw(const SMCKeyMeta *m, uint8_t bytes[32]){
  SMCParam in={0},out={0}; in.key=m->key; in.keyInfo.dataSize=m->size; in.data8=5;
  if(smc_call(&in,&out)!=KERN_SUCCESS) return -1; if(out.result!=0) return -(100+out.result);
  memcpy(bytes,out.bytes,32); return 0; }

static inline uint64_t rd_uint(const uint8_t*b,int n,int le){ uint64_t v=0; for(int i=0;i<n;i++){ int idx = le? (n-1-i) : i; v=(v<<8)|b[idx]; } return v; }
// 返回 0 = 成功，val 为数值；-1 = 不能按数值解码
static int smc_decode(const SMCKeyMeta *m, const uint8_t *b, double *val){
  char t[5]; s4(m->type,t); int le = (m->attr & 0x04)!=0; int n=(int)m->size;
  if(!strcmp(t,"flt ") && n==4){ float f; uint32_t u=(uint32_t)rd_uint(b,4,le); memcpy(&f,&u,4); *val=f; return 0; }
  if(!strcmp(t,"ioft") && n==8){ int64_t v=(int64_t)rd_uint(b,8,le); *val=v/65536.0; return 0; }
  if(!strcmp(t,"ioft") && n==4){ int32_t v=(int32_t)rd_uint(b,4,le); *val=v/65536.0; return 0; }
  if(!strcmp(t,"sp78") && n==2){ int16_t v=(int16_t)rd_uint(b,2,le); *val=v/256.0; return 0; }
  if(!strcmp(t,"fpe2") && n==2){ uint16_t v=(uint16_t)rd_uint(b,2,le); *val=v/4.0; return 0; }
  if(!strcmp(t,"si8 ") && n==1){ *val=(int8_t)b[0]; return 0; }
  if(!strcmp(t,"si16") && n==2){ *val=(int16_t)rd_uint(b,2,le); return 0; }
  if(!strcmp(t,"si32") && n==4){ *val=(int32_t)rd_uint(b,4,le); return 0; }
  if(!strcmp(t,"si64") && n==8){ *val=(double)(int64_t)rd_uint(b,8,le); return 0; }
  if((!strcmp(t,"ui8 ")||!strcmp(t,"flag")) && n==1){ *val=b[0]; return 0; }
  if(!strcmp(t,"ui16") && n==2){ *val=(double)rd_uint(b,2,le); return 0; }
  if(!strcmp(t,"ui32") && n==4){ *val=(double)rd_uint(b,4,le); return 0; }
  if(!strcmp(t,"ui64") && n==8){ *val=(double)rd_uint(b,8,le); return 0; }
  return -1; }
static int smc_count(void){ SMCKeyMeta m; uint8_t b[32]; double v; if(smc_keyinfo(k4("#KEY"),&m)) return 0; if(smc_read_raw(&m,b)) return 0; if(smc_decode(&m,b,&v)) return 0; return (int)v; }
static int smc_key_at(int i, uint32_t *key){ SMCParam in={0},out={0}; in.data8=8; in.data32=(uint32_t)i; if(smc_call(&in,&out)!=KERN_SUCCESS||out.result) return -1; *key=out.key; return 0; }
#include <time.h>
static inline double thread_cpu_ms(void){ struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&ts); return ts.tv_sec*1e3+ts.tv_nsec/1e6; }
static inline double wall_s(void){ struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }
