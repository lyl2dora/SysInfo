// 探针：用合成输入检验 td_assignPerfLevels 在没有实机的拓扑上的行为（M1 4+4 两档核数相等、M1 Ultra 多 die、
// 假想三档芯片、核数相等且 DVFS 表缺失只能靠 L2 的情况、两档完全无法区分的情况）。不访问硬件。
#include "topo_discover.h"
typedef struct { const char* name; int logical, cpusperl2; long long l2; } P;
typedef struct { const char* compat; int ncpu, ncl, clSize; uint32_t l2MB; double maxMHz; } C;
static void run(const char* title, P* p, int np, C* c, int nc){
  td_npl=np; for(int i=0;i<np;i++){ strcpy(td_pl[i].name,p[i].name); td_pl[i].logical=p[i].logical; td_pl[i].cpusperl2=p[i].cpusperl2; td_pl[i].l2=p[i].l2<<20; }
  td_ncc=nc; for(int j=0;j<nc;j++){ memset(&td_cc[j],0,sizeof td_cc[j]); strcpy(td_cc[j].compat,c[j].compat); td_cc[j].ncpu=c[j].ncpu; td_cc[j].ncl=c[j].ncl; td_cc[j].clSize=c[j].clSize; td_cc[j].l2=c[j].l2MB<<20; td_cc[j].maxMHz=c[j].maxMHz; }
  td_assignPerfLevels(); printf("== %s\n", title);
  for(int j=0;j<nc;j++) printf("  class %-14s cpus=%2d clSize=%d l2=%2uMB max=%4.0f -> byCount=%2d byFreq=%2d byL2=%2d => perflevel %d (%s)\n", c[j].compat, c[j].ncpu, c[j].clSize, c[j].l2MB, c[j].maxMHz, td_cc[j].plByCount, td_cc[j].plByFreq, td_cc[j].plByL2, td_cc[j].perflevel, td_cc[j].perflevel>=0? td_pl[td_cc[j].perflevel].name : "UNRESOLVED"); }
int main(void){
  { P p[]={{"Performance",4,4,12},{"Efficiency",4,4,4}}; C c[]={{"icestorm/E",4,1,4,4,2064},{"firestorm/P",4,1,4,12,3204}}; run("M1 (4P+4E, counts equal)",p,2,c,2); }
  { P p[]={{"Performance",4,4,12},{"Efficiency",4,4,4}}; C c[]={{"icestorm/E",4,1,4,4,0},{"firestorm/P",4,1,4,12,0}}; run("M1, DVFS tables unmatched (L2 only)",p,2,c,2); }
  { P p[]={{"Performance",16,4,48},{"Efficiency",4,2,4}}; C c[]={{"icestorm/E",4,2,2,4,2064},{"firestorm/P",16,4,4,12,3204}}; run("M1 Ultra (2 dies)",p,2,c,2); }
  { P p[]={{"Super",4,4,16},{"Performance",6,6,8},{"Efficiency",4,4,4}}; C c[]={{"x/E",4,1,4,4,2400},{"y/M",6,1,6,8,4000},{"z/P",4,1,4,16,4800}}; run("hypothetical 3-level (4S+6P+4E; S and E counts equal)",p,3,c,3); }
  { P p[]={{"Performance",4,4,12},{"Efficiency",4,4,12}}; C c[]={{"a/E",4,1,4,12,0},{"b/P",4,1,4,12,0}}; run("pathological: counts, L2 equal, no tables",p,2,c,2); }
  return 0; }
