// cpuburn.c - N spinning threads for S seconds at a given QoS (ui|bg|def). Own process only.
// build: xcrun clang -O2 cpuburn.c -o cpuburn ; usage: cpuburn <threads> <seconds> <ui|bg|def>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/time.h>
static double wall(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
static double T; static qos_class_t Q;
static void* w(void*a){ if(Q!=QOS_CLASS_UNSPECIFIED) pthread_set_qos_class_self_np(Q,0); double end=wall()+T; volatile double x=1.0001; unsigned long n=0;
  while(1){ for(int i=0;i<200000;i++){ x=x*1.0000001+0.0000001; } n++; if(wall()>=end) break; } return (void*)n; }
int main(int c,char**v){ int n=atoi(v[1]); T=atof(v[2]); Q= !strcmp(v[3],"ui")?QOS_CLASS_USER_INTERACTIVE: !strcmp(v[3],"bg")?QOS_CLASS_BACKGROUND:QOS_CLASS_UNSPECIFIED;
  pthread_t th[64]; for(int i=0;i<n;i++) pthread_create(&th[i],0,w,0); unsigned long tot=0; for(int i=0;i<n;i++){ void*r; pthread_join(th[i],&r); tot+=(unsigned long)r; }
  printf("cpuburn %d threads qos=%s %.0fs iterations=%lu\n",n,v[3],T,tot); return 0; }
