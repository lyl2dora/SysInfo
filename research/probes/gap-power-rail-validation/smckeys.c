// smckeys.c - read-only: print the given SMC keys (flt/sp78/ui*) N times at 1 Hz. Uses smc_ro.h (selectors 9/5/8 only).
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/time.h>
#include "smc_ro.h"
int main(int c,char**v){ if(smc_open()) return 1; int n=atoi(v[1]); for(int i=0;i<n;i++){ struct timeval tv; gettimeofday(&tv,0); printf("%ld",tv.tv_sec); for(int k=2;k<c;k++) printf(" %s=%.3f",v[k],smc_val(v[k])); printf("\n"); fflush(stdout); if(i<n-1) sleep(1);} return 0; }
