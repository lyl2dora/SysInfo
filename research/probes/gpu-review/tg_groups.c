// Review probe: read all Tg* SMC keys (read-only) at idle, twice 2 s apart; shows per-key values to reveal partition grouping.
// build: xcrun clang -O1 -o tg_groups tg_groups.c -framework IOKit -framework CoreFoundation
#include "smc.h"
#include <stdio.h>
#include <unistd.h>
int main(void){ if(smc_open()){ printf("smc open failed\n"); return 1; } int n=smc_count(); char keys[128][5]; int nk=0;
  for(int i=0;i<n;i++){ char nm[5]; if(!smc_key_at(i,nm)&&nm[0]=='T'&&nm[1]=='g'&&nk<128) strcpy(keys[nk++],nm); }
  for(int r=0;r<2;r++){ printf("read %d:",r); for(int k=0;k<nk;k++){ char t[5]; uint8_t b[32]; uint32_t sz; smc_read(k4(keys[k]),t,b,&sz); printf(" %s=%.3f(%s)",keys[k],smc_val(keys[k]),t);} printf("\n"); sleep(2); }
  return 0; }
