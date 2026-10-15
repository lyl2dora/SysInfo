// ior_group_list.c — 列出名字包含给定子串的 IOReport 组的全部通道（组/子组/名称/单位/格式/2 s 内的变化），用于找 PMP 能量直方图、TVPM 温度等。只读。
// 用法：ior_group_list <组名子串> [间隔秒=2]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "ioreport.h"
CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
int32_t IOReportStateGetCount(CFDictionaryRef); CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef,int32_t); int64_t IOReportStateGetResidency(CFDictionaryRef,int32_t);
int32_t IOReportHistogramGetBucketCount(CFDictionaryRef); int64_t IOReportHistogramGetBucketHits(CFDictionaryRef,int32_t); int64_t IOReportHistogramGetBucketSum(CFDictionaryRef,int32_t);
int main(int argc,char**argv){
  const char*pat=argv[1]; double iv=argc>2?atof(argv[2]):2;
  CFMutableDictionaryRef all=IOReportCopyAllChannels(0,0); CFArrayRef arr=CFDictionaryGetValue(all,CFSTR("IOReportChannels"));
  CFMutableArrayRef keep=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
  for(CFIndex i=0;i<CFArrayGetCount(arr);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); char g[96]; cfstr(IOReportChannelGetGroup(c),g,96); if(strstr(g,pat)) CFArrayAppendValue(keep,c); }
  CFDictionarySetValue(all,CFSTR("IOReportChannels"),keep);
  CFMutableDictionaryRef subbed=NULL; IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,all,&subbed,0,NULL);
  CFDictionaryRef a=IOReportCreateSamples(sub,subbed,NULL); usleep((useconds_t)(iv*1e6)); CFDictionaryRef b=IOReportCreateSamples(sub,subbed,NULL);
  CFDictionaryRef d=IOReportCreateSamplesDelta(a,b,NULL); CFArrayRef da=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
  printf("channels in groups matching '%s': %ld\n",pat,(long)CFArrayGetCount(da));
  for(CFIndex i=0;i<CFArrayGetCount(da);i++){ CFDictionaryRef c=CFArrayGetValueAtIndex(da,i); char g[96],sg[96],nm[96],u[24];
    cfstr(IOReportChannelGetGroup(c),g,96); cfstr(IOReportChannelGetSubGroup(c),sg,96); cfstr(IOReportChannelGetChannelName(c),nm,96); cfstr(IOReportChannelGetUnitLabel(c),u,24);
    int fmt=IOReportChannelGetFormat(c); printf("  [%s | %s] %-26s unit=%-4s fmt=%d",g,sg,nm,u,fmt);
    if(fmt==1) printf(" delta=%lld",(long long)IOReportSimpleGetIntegerValue(c,NULL));
    else if(fmt==2){ int n=IOReportStateGetCount(c); int64_t tot=0; for(int s=0;s<n;s++) tot+=IOReportStateGetResidency(c,s); printf(" states=%d resid_delta=%lld",n,(long long)tot); }
    else if(fmt==3){ int n=IOReportHistogramGetBucketCount(c); int64_t hits=0,sum=0; for(int s=0;s<n;s++){ hits+=IOReportHistogramGetBucketHits(c,s); } printf(" buckets=%d hits_delta=%lld",n,(long long)hits); (void)sum; }
    printf("\n"); }
  return 0; }
