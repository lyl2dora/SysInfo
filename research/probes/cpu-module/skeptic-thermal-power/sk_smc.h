// sk_smc.h — skeptic-thermal-power 独立实现的只读 AppleSMC 访问（selector 2；cmd 9=GetKeyInfo, 5=ReadKey, 8=GetKeyFromIndex）。绝不写入。
#pragma once
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
typedef struct {
  uint32_t key;
  struct { uint8_t major, minor, build, rsv; uint16_t release; } vers;
  struct { uint16_t version, length; uint32_t cpu, gpu, mem; } plimit;
  struct { uint32_t size, type; uint8_t attr; } info;
  uint8_t result, status, cmd; uint32_t data32; uint8_t bytes[32];
} SkSMC;
typedef struct { uint32_t key, type, size; uint8_t attr; char name[5], tname[5]; } SkKey;
static io_connect_t sk_conn;
static inline uint32_t sk_k(const char*s){ return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|((uint32_t)(uint8_t)s[2]<<8)|(uint8_t)s[3]; }
static inline void sk_s(uint32_t k,char*o){ for(int i=0;i<4;i++) o[i]=(char)(k>>(24-8*i)); o[4]=0; }
static int sk_open(void){ io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC")); if(!s) return -1;
  kern_return_t r=IOServiceOpen(s,mach_task_self(),0,&sk_conn); IOObjectRelease(s); return r==KERN_SUCCESS?0:-1; }
static inline int sk_call(SkSMC*in,SkSMC*out){ size_t n=sizeof(SkSMC); memset(out,0,sizeof(*out)); return IOConnectCallStructMethod(sk_conn,2,in,sizeof(SkSMC),out,&n)==KERN_SUCCESS && out->result==0 ? 0 : -1; }
static int sk_info(uint32_t key, SkKey*k){ SkSMC in={0},out; in.key=key; in.cmd=9; if(sk_call(&in,&out)) return -1;
  k->key=key; k->type=out.info.type; k->size=out.info.size; k->attr=out.info.attr; sk_s(key,k->name); sk_s(k->type,k->tname); return 0; }
static int sk_index(uint32_t i, uint32_t*key){ SkSMC in={0},out; in.cmd=8; in.data32=i; if(sk_call(&in,&out)) return -1; *key=out.key; return 0; }
static int sk_raw(const SkKey*k, uint8_t*b){ SkSMC in={0},out; in.key=k->key; in.info.size=k->size; in.cmd=5; if(sk_call(&in,&out)) return -1; memcpy(b,out.bytes,32); return 0; }
// 数值解码：Apple 芯片上 flt 为小端；其他整型按 attr 位 0x04（置位=小端）判断
static int sk_val(const SkKey*k, const uint8_t*b, double*v){
  int le=(k->attr&0x04)!=0; uint64_t u=0; int n=(int)k->size; if(n>8) return -1;
  for(int i=0;i<n;i++){ int idx=le? n-1-i : i; u=(u<<8)|b[idx]; }
  const char*t=k->tname;
  if(!strcmp(t,"flt ")&&n==4){ uint32_t x=(uint32_t)u; float f; memcpy(&f,&x,4); *v=f; return 0; }
  if(!strcmp(t,"ioft")&&n==8){ *v=(double)(int64_t)u/65536.0; return 0; }
  if(!strcmp(t,"sp78")&&n==2){ *v=(int16_t)u/256.0; return 0; }
  if(!strcmp(t,"fpe2")&&n==2){ *v=(uint16_t)u/4.0; return 0; }
  if(!strcmp(t,"ui8 ")||!strcmp(t,"ui16")||!strcmp(t,"ui32")||!strcmp(t,"flag")){ *v=(double)u; return 0; }
  if(!strcmp(t,"si8 ")&&n==1){ *v=(int8_t)u; return 0; } if(!strcmp(t,"si16")&&n==2){ *v=(int16_t)u; return 0; }
  return -1; }
static inline double sk_tcpu_ms(void){ struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID,&ts); return ts.tv_sec*1e3+ts.tv_nsec/1e6; }
static inline double sk_wall(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }
static inline double sk_epoch(void){ struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); return ts.tv_sec+ts.tv_nsec/1e9; }
// 列出全部键（返回数量），可按首字母集合与类型过滤
static int sk_enum(SkKey*out,int max,const char*first,int only_flt){ SkKey c; uint8_t b[32]; SkKey nk; if(sk_info(sk_k("#KEY"),&nk)||sk_raw(&nk,b)) return 0;
  double dn; if(sk_val(&nk,b,&dn)) return 0; int n=(int)dn, m=0;
  for(int i=0;i<n&&m<max;i++){ uint32_t k; if(sk_index(i,&k)) continue; char nm[5]; sk_s(k,nm); if(first&&!strchr(first,nm[0])) continue;
    if(sk_info(k,&c)) continue; if(only_flt&&strcmp(c.tname,"flt ")) continue; out[m++]=c; }
  return m; }
