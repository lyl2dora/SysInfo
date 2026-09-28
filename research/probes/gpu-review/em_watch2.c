// Review probe: watch ALL simple channels in "Energy Model" (absolute values), log every change per driver,
// with a fresh subscription created every N minutes too (to rule out a stale-subscription artifact).
// usage: em_watch2 <periodSec> <totalSec>
// build: xcrun clang -O1 -o em_watch2 em_watch2.c -lIOReport -framework CoreFoundation
#include "ior.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <stdlib.h>
#define MAXC 512
static char names[MAXC][96], drv[MAXC][64]; static int64_t last[MAXC]; static int nch=0;
static int idx(const char*n,const char*d){ for(int i=0;i<nch;i++) if(!strcmp(names[i],n)&&!strcmp(drv[i],d)) return i; if(nch>=MAXC) return -1; strcpy(names[nch],n); strcpy(drv[nch],d); last[nch]=INT64_MIN; return nch++; }
static void ts(char*b){ time_t t=time(NULL); strftime(b,32,"%H:%M:%S",localtime(&t)); }
int main(int argc,char**argv){
  double period=argc>1?atof(argv[1]):2; int total=argc>2?atoi(argv[2]):60;
  CFMutableDictionaryRef sc=NULL; IOReportSubscriptionRef sub=NULL; CFMutableDictionaryRef m=NULL;
  time_t t0=time(NULL), lastsub=0; int samples=0;
  while(time(NULL)-t0 < total){
    if(!sub || time(NULL)-lastsub>=600){ // fresh subscription every 10 min
      CFDictionaryRef ch=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
      m=CFDictionaryCreateMutableCopy(kCFAllocatorDefault,0,ch); CFRelease(ch);
      sub=IOReportCreateSubscription(NULL,m,&sc,0,NULL); lastsub=time(NULL);
      char b[32]; ts(b); printf("%s new subscription %p\n",b,(void*)sub); fflush(stdout);
    }
    CFDictionaryRef s=IOReportCreateSamples(sub,sc,NULL); samples++;
    CFArrayRef arr=CFDictionaryGetValue(s,CFSTR("IOReportChannels"));
    int changedPMGR=0, changedOther=0; char line[8192]; line[0]=0;
    for(CFIndex i=0;i<CFArrayGetCount(arr);i++){
      CFDictionaryRef c=CFArrayGetValueAtIndex(arr,i); if(IOReportChannelGetFormat(c)!=1) continue;
      char n[96],d[64],u[16]; cs(IOReportChannelGetChannelName(c),n,96); cs(IOReportChannelGetDriverName(c),d,64); cs(IOReportChannelGetUnitLabel(c),u,16);
      int k=idx(n,d); if(k<0) continue; int64_t v=IOReportSimpleGetIntegerValue(c,0);
      if(last[k]!=INT64_MIN && v!=last[k]){
        if(strstr(d,"PMGR")) { changedPMGR++; if(!strcmp(n,"CPU Energy")||!strcmp(n,"GPU0")||!strcmp(n,"ANE0")||!strcmp(n,"DRAM0")||!strcmp(n,"AVE0")){ char t[160]; snprintf(t,160," %s +%lld%s",n,(long long)(v-last[k]),u); strncat(line,t,8000);} }
        else { changedOther++; if(samples%30==0){ char t[200]; snprintf(t,200," [%s|%s +%lld%s]",n,d,(long long)(v-last[k]),u); strncat(line,t,8000);} }
      }
      last[k]=v;
    }
    char b[32]; ts(b);
    if(changedPMGR) printf("%s PMGR CHANGE: %d PMGR channels changed:%s | nonPMGR changed=%d\n",b,changedPMGR,line,changedOther);
    else if(samples%30==0) printf("%s heartbeat: 0 PMGR changes; nonPMGR changed=%d%s\n",b,changedOther,line);
    fflush(stdout); CFRelease(s); usleep((useconds_t)(period*1e6));
  }
  return 0;
}
