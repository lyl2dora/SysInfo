// sk_em_struct.c — 列出 Energy Model 全部通道的累计值（J），并检验「簇级通道 = 同前缀每核通道之和」这一结构规则。只读。
// 规则实现：对每个通道 A，收集名字以 A 为前缀、且剩余部分只含数字或「_数字」的通道 B_i，若 ≥2 个则比较 A 与 ΣB_i。
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include "sk_ior.h"
typedef struct { char n[64]; char drv[96]; double j; } Ch;
static Ch C[1024]; static int nc;
static int is_suffix_num(const char*s){ if(*s=='_') s++; if(!*s) return 0; for(;*s;s++) if(!isdigit((unsigned char)*s)) return 0; return 1; }
int main(void){
  CFMutableDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0); CFMutableDictionaryRef sd=NULL;
  IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,ch,&sd,0,NULL); CFDictionaryRef s=IOReportCreateSamples(sub,sd,NULL);
  CFArrayRef a=CFDictionaryGetValue(s,CFSTR("IOReportChannels"));
  for(CFIndex i=0;i<CFArrayGetCount(a)&&nc<1024;i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(a,i); char u[16]; sk_cf(IOReportChannelGetUnitLabel(c),u,16);
    sk_cf(IOReportChannelGetChannelName(c),C[nc].n,64); sk_cf(IOReportChannelGetDriverName(c),C[nc].drv,96); C[nc].j=IOReportSimpleGetIntegerValue(c,NULL)*sk_unit_to_J(u); nc++; }
  printf("通道数 %d；驱动示例 %s\n",nc,nc?C[0].drv:"-");
  for(int i=0;i<nc;i++){ double sum=0; int m=0; char list[512]=""; size_t L=strlen(C[i].n);
    for(int j=0;j<nc;j++) if(j!=i && !strncmp(C[j].n,C[i].n,L) && is_suffix_num(C[j].n+L)){ sum+=C[j].j; m++; if(strlen(list)<400){ strcat(list," "); strcat(list,C[j].n);} }
    if(m>=2) printf("%-14s = %.1f J；Σ(%d 个%s) = %.1f J；比 %.4f\n",C[i].n,C[i].j,m,list,sum,C[i].j? sum/C[i].j:0); }
  printf("\n名字含 CPU/ACC/CPM 的通道：\n"); for(int i=0;i<nc;i++) if(strstr(C[i].n,"CPU")||strstr(C[i].n,"ACC")||strstr(C[i].n,"CPM")) printf("  %s=%.1f",C[i].n,C[i].j); printf("\n");
  return 0; }
