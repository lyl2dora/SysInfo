// 探针：列出 IOReport 全部 (组, 子组) 与通道数、驱动名，便于比较两台机器上有哪些 CPU 相关组（只读）。
#include <stdio.h>
#include <string.h>
#include "ioreport.h"
static void cs(CFStringRef s, char* b, int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
int main(void){
  CFMutableDictionaryRef all=IOReportCopyAllChannels(0,0); CFArrayRef arr=CFDictionaryGetValue(all,CFSTR("IOReportChannels"));
  char prev[256]=""; int cnt=0; char drv[128]="";
  printf("total channels=%ld\n", CFArrayGetCount(arr));
  for(CFIndex i=0;i<=CFArrayGetCount(arr);i++){
    char key[256]="", d[128]="";
    if(i<CFArrayGetCount(arr)){ CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i); char g[128], sg[128]; cs(IOReportChannelGetGroup(ch),g,128); cs(IOReportChannelGetSubGroup(ch),sg,128); cs(IOReportChannelGetDriverName(ch),d,128); char* p=strstr(d," <id"); if(p) *p=0; snprintf(key,256,"%s | %s",g,sg); }
    if(strcmp(key,prev)){ if(prev[0]) printf("%5d  %-80s  %s\n", cnt, prev, drv); strcpy(prev,key); strcpy(drv,d); cnt=0; }
    cnt++; }
  return 0;
}
