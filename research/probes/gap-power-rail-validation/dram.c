// dram.c - DRAM-heavy memcpy: N threads each copying between two private 512 MiB buffers for S seconds; reports GB/s (read+write).
// build: xcrun clang -O2 dram.c -o dram ; usage: dram <threads> <seconds>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/time.h>
static double wall(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
#define SZ (512UL<<20)
static double T; static _Atomic unsigned long long bytes;
static void* w(void*a){ char*s=malloc(SZ),*d=malloc(SZ); memset(s,1,SZ); memset(d,2,SZ); double end=wall()+T; while(wall()<end){ memcpy(d,s,SZ); atomic_fetch_add(&bytes,2*SZ); char*t=s;s=d;d=t; } free(s); free(d); return 0; }
int main(int c,char**v){ int n=atoi(v[1]); T=atof(v[2]); pthread_t th[64]; double t0=wall(); for(int i=0;i<n;i++) pthread_create(&th[i],0,w,0);
  double last=t0; unsigned long long lb=0; while(wall()<t0+T+0.5){ struct timespec ts={1,0}; nanosleep(&ts,0); double now=wall(); unsigned long long b=bytes; printf("t=%.0f %.1f GB/s\n",now-t0,(b-lb)/1e9/(now-last)); fflush(stdout); lb=b; last=now; if(now>t0+T) break; }
  for(int i=0;i<n;i++) pthread_join(th[i],0); printf("dram %d threads: total %.1f GB in %.1fs = %.1f GB/s (r+w)\n",n,bytes/1e9,wall()-t0,bytes/1e9/(wall()-t0)); return 0; }
