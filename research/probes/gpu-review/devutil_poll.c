// Review probe: poll IOAccelerator PerformanceStatistics "Device Utilization %" every 5 ms to see its update cadence / window.
// usage: devutil_poll <seconds>   build: xcrun clang -O1 -o devutil_poll devutil_poll.c -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/time.h>
static double now(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec+t.tv_usec/1e6; }
int main(int argc,char**argv){ double secs=argc>1?atof(argv[1]):3; io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOAccelerator"));
  double t0=now(), lastchange=t0; int last=-99, n=0, changes=0; double sum=0; int hist[11]={0};
  while(now()-t0<secs){ CFDictionaryRef ps=IORegistryEntryCreateCFProperty(s,CFSTR("PerformanceStatistics"),kCFAllocatorDefault,0); int v=-1;
    if(ps){ CFNumberRef x=CFDictionaryGetValue(ps,CFSTR("Device Utilization %")); if(x) CFNumberGetValue(x,kCFNumberIntType,&v); CFRelease(ps);} 
    n++; sum+=v; hist[v>=100?10:(v<0?0:v/10)]++;
    if(v!=last){ changes++; if(changes<=40) printf("t=%.3f v=%d (held %.0f ms)\n",now()-t0,v,(now()-lastchange)*1000); last=v; lastchange=now(); }
    usleep(argc>2?atoi(argv[2]):5000); }
  printf("samples=%d changes=%d mean=%.1f; decile histogram:",n,changes,sum/n); for(int i=0;i<11;i++) printf(" %d",hist[i]); printf("\n"); return 0; }
