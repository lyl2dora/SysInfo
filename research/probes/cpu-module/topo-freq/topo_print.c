// 探针：只做拓扑与 DVFS 表发现并打印（无负载）。算法见 topo_discover.h。
#include "topo_discover.h"
int main(void){
  td_discover(); td_print(stdout);
  printf("\nperf-domains:"); for(int i=0;i<td_npd;i++) printf(" %s->vs%d", td_pd[i].name, td_pd[i].vs); printf("\n");
  printf("valid CPU-like tables:"); for(int i=0;i<td_ntbl;i++) if(td_tbl[i].valid) printf(" vs%d%s(n=%d,%s,%.0f-%.0f)", td_tbl[i].key, td_tbl[i].sram?"-sram":"", td_tbl[i].n, td_tbl[i].unit, td_tbl[i].mhz[0], td_tbl[i].mhz[td_tbl[i].n-1]); printf("\n");
  printf("complex channels:"); for(int x=0;x<td_ncx;x++) printf(" %s(nV=%d)", td_cxChan[x], td_cxNV[x]); printf("\n");
  // host_processor_info 的核数应等于 DT 核数与逐核通道数
  natural_t n; processor_info_array_t info; mach_msg_type_number_t cnt;
  host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt);
  printf("host_processor_info cpus=%u, DT cpus=%d, IOReport core channels=%d, hw.logicalcpu_max=%lld\n", n, td_ncpu, td_ncoreChan, td_sint("hw.logicalcpu_max"));
  return 0;
}
