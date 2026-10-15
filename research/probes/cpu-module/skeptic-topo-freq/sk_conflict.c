// 复核探针 8：不访问硬件，只喂合成输入给 topo-freq/topo_discover.h 的 td_assignPerfLevels，
// 检查其声明的「三种依据交叉核对，冲突判 degraded」是否真的实现（编译时引用 ../topo-freq/topo_discover.h）。
#include "../topo-freq/topo_discover.h"
static void run(const char* title, double fE, double fP, uint32_t l2E, uint32_t l2P){
  td_npl=2; strcpy(td_pl[0].name,"Performance"); td_pl[0].logical=8; td_pl[0].cpusperl2=4; strcpy(td_pl[1].name,"Efficiency"); td_pl[1].logical=4; td_pl[1].cpusperl2=4;
  td_ncc=2; memset(td_cc,0,sizeof td_cc);
  strcpy(td_cc[0].compat,"x/E"); td_cc[0].ncpu=4; td_cc[0].ncl=1; td_cc[0].clSize=4; td_cc[0].l2=l2E<<20; td_cc[0].maxMHz=fE;
  strcpy(td_cc[1].compat,"y/P"); td_cc[1].ncpu=8; td_cc[1].ncl=2; td_cc[1].clSize=4; td_cc[1].l2=l2P<<20; td_cc[1].maxMHz=fP;
  td_assignPerfLevels(); printf("== %s\n", title);
  for(int j=0;j<2;j++) printf("  class %s byCount=%d byFreq=%d byL2=%d => perflevel %d  (no degraded/conflict flag exists in TDClass)\n", td_cc[j].compat, td_cc[j].plByCount, td_cc[j].plByFreq, td_cc[j].plByL2, td_cc[j].perflevel); }
int main(void){
  run("M2-like, consistent", 2424, 3504, 4, 8);
  run("M2-like, DVFS tables swapped between classes (freq evidence contradicts count)", 3504, 2424, 4, 8);
  run("M2-like, freq AND L2 both contradict count", 3504, 2424, 8, 4);
  return 0; }
