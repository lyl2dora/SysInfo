// smc_enum.c — 只读：枚举全部 SMC 键，打印 类型/大小/属性/数值（不能按数值解码的打印原始十六进制）。
// 同时报告全枚举耗时（线程 CPU 与墙钟）和按首两字符分组的 T*/P* 键族统计。用法：smc_enum > out.txt
#include <stdio.h>
#include <stdlib.h>
#include "smc_ro.h"
int main(void){
  if(smc_open()){ printf("AppleSMC open failed\n"); return 1; }
  double c0=thread_cpu_ms(), w0=wall_s();
  int n=smc_count(); printf("#KEY=%d\n", n);
  SMCKeyMeta *metas=calloc(n,sizeof(SMCKeyMeta)); int nm=0, nokinfo=0, nread=0;
  for(int i=0;i<n;i++){ uint32_t k; if(smc_key_at(i,&k)) continue; SMCKeyMeta m; if(smc_keyinfo(k,&m)){ nokinfo++; continue; } metas[nm++]=m; }
  double c1=thread_cpu_ms(), w1=wall_s();
  printf("enumerate+keyinfo: %d keys, %d keyinfo fail, thread CPU %.1f ms, wall %.1f ms\n", nm, nokinfo, c1-c0, (w1-w0)*1e3);
  for(int i=0;i<nm;i++){ char k[5],t[5]; s4(metas[i].key,k); s4(metas[i].type,t); uint8_t b[32]; int r=smc_read_raw(&metas[i],b);
    if(r){ printf("%s %s sz=%u attr=0x%02x READFAIL(%d)\n",k,t,metas[i].size,metas[i].attr,r); continue; } nread++;
    double v; if(!smc_decode(&metas[i],b,&v)) printf("%s %s sz=%u attr=0x%02x val=%.4f\n",k,t,metas[i].size,metas[i].attr,v);
    else { printf("%s %s sz=%u attr=0x%02x hex=",k,t,metas[i].size,metas[i].attr); for(uint32_t j=0;j<metas[i].size&&j<32;j++) printf("%02x",b[j]); printf("\n"); } }
  double c2=thread_cpu_ms(), w2=wall_s();
  printf("read all: %d ok, thread CPU %.1f ms, wall %.1f ms\n", nread, c2-c1, (w2-w1)*1e3);
  return 0; }
