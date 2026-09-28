// smcall.c - read-only: enumerate ALL SMC keys of type 'flt ', sample them for 8 s to find the ones that move, then log only the
// moving (non-T/V/I/F-prefixed) keys at 1 Hz until <end_epoch> into <out>.csv.  Selectors 8/9/5 only (index/keyinfo/read).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <sys/time.h>
#include "smc_ro.h"
static double wall(void){ struct timeval t; gettimeofday(&t,NULL); return t.tv_sec + t.tv_usec/1e6; }
static int readf(uint32_t key, float *f){ SMCParam in={0},out={0}; in.key=key; in.keyInfo.dataSize=4; in.data8=5; if(smc_call(&in,&out)!=KERN_SUCCESS||out.result) return -1; memcpy(f,out.bytes,4); return 0; }
int main(int c,char**v){ if(smc_open()) return 1; double end=atof(v[2]); int n=smc_count(); uint32_t *keys=malloc(n*4); int nk=0;
  for(int i=0;i<n;i++){ char nm[5]; if(smc_key_at(i,nm)) continue; SMCParam in={0},out={0}; in.key=k4(nm); in.data8=9; if(smc_call(&in,&out)||out.result) continue; char t[5]; s4(out.keyInfo.dataType,t); if(!strcmp(t,"flt ")&&out.keyInfo.dataSize==4) keys[nk++]=k4(nm); }
  float *v0=malloc(nk*4), cur; int *mv=calloc(nk,sizeof(int));
  for(int i=0;i<nk;i++) readf(keys[i],&v0[i]);
  for(int s=0;s<8;s++){ sleep(1); for(int i=0;i<nk;i++){ if(!readf(keys[i],&cur) && cur!=v0[i]) mv[i]=1; } }
  char fn[512]; snprintf(fn,512,"%s.csv",v[1]); FILE*fo=fopen(fn,"w"); fprintf(fo,"epoch"); int nsel=0;
  for(int i=0;i<nk;i++){ char nm[5]; s4(keys[i],nm); if(mv[i] && !strchr("TVIF",nm[0])){ fprintf(fo,",%s",nm); keys[nsel++]=keys[i]; } }
  fprintf(fo,"\n"); fprintf(stderr,"flt keys=%d, moving non-TVIF selected=%d\n",nk,nsel);
  double next=floor(wall())+1; while(wall()<end){ double now=wall(); if(now<next) usleep((useconds_t)((next-now)*1e6)); next+=1; fprintf(fo,"%.3f",wall()); for(int i=0;i<nsel;i++){ float f=NAN; readf(keys[i],&f); fprintf(fo,",%.5f",f);} fprintf(fo,"\n"); fflush(fo); }
  fclose(fo); return 0; }
