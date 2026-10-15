// 探针：host_processor_info 与 host_statistics(HOST_CPU_LOAD_INFO) 在 20 Hz 连续调用下的「陈旧」比例、
// 每核 tick 速率（应为 100/s），以及两者合计值是否一致（只读，约 4 s）。
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#define MAXC 256
static host_t H;
static int hpi(unsigned out[MAXC][4]){ natural_t n; processor_info_array_t info; mach_msg_type_number_t c;
  if(host_processor_info(H, PROCESSOR_CPU_LOAD_INFO, &n, &info, &c)) return -1;
  for(unsigned i=0;i<n;i++) for(int s=0;s<4;s++) out[i][s]=(unsigned)info[i*CPU_STATE_MAX+s];
  vm_deallocate(mach_task_self(), (vm_address_t)info, c*sizeof(int)); return (int)n; }
int main(void){
  H=mach_host_self(); unsigned a[MAXC][4], b[MAXC][4]; host_cpu_load_info_data_t x, y; mach_msg_type_number_t c;
  int n=hpi(a); c=HOST_CPU_LOAD_INFO_COUNT; host_statistics(H, HOST_CPU_LOAD_INFO, (host_info_t)&x, &c);
  unsigned a0[MAXC][4]; memcpy(a0,a,sizeof a); host_cpu_load_info_data_t x0=x;
  int staleH=0, staleS=0, N=80; uint64_t t0=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  for(int i=0;i<N;i++){ usleep(50000); hpi(b); c=HOST_CPU_LOAD_INFO_COUNT; host_statistics(H, HOST_CPU_LOAD_INFO, (host_info_t)&y, &c);
    if(!memcmp(a,b,sizeof(unsigned)*4*n)) staleH++; if(!memcmp(&x,&y,sizeof x)) staleS++; memcpy(a,b,sizeof a); x=y; }
  double el=(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)-t0)/1e9;
  printf("cpus=%d, %d calls at 20 Hz over %.2f s: host_processor_info identical-to-previous=%d, host_statistics(HOST_CPU_LOAD_INFO) identical-to-previous=%d\n", n, N, el, staleH, staleS);
  double rate=0; unsigned long long su=0, ss=0, si=0, sn=0;
  for(int i=0;i<n;i++){ unsigned long long d=0; for(int s=0;s<4;s++) d+=a[i][s]-a0[i][s]; rate+=d/el; su+=a[i][0]-a0[i][0]; ss+=a[i][1]-a0[i][1]; si+=a[i][2]-a0[i][2]; sn+=a[i][3]-a0[i][3]; }
  printf("per-core tick rate: %.1f ticks/s/core (expect 100)\n", rate/n);
  printf("sum over cores delta: user=%llu sys=%llu idle=%llu nice=%llu | HOST_CPU_LOAD_INFO delta: user=%u sys=%u idle=%u nice=%u\n", su, ss, si, sn,
    x.cpu_ticks[CPU_STATE_USER]-x0.cpu_ticks[CPU_STATE_USER], x.cpu_ticks[CPU_STATE_SYSTEM]-x0.cpu_ticks[CPU_STATE_SYSTEM], x.cpu_ticks[CPU_STATE_IDLE]-x0.cpu_ticks[CPU_STATE_IDLE], x.cpu_ticks[CPU_STATE_NICE]-x0.cpu_ticks[CPU_STATE_NICE]);
  return 0; }
