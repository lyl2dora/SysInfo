// perflevel_split.c - rusage_info_v6 的「p」字段（ri_user_ptime/ri_system_ptime/ri_pcycles/ri_pinstructions/ri_penergy_nj）
// 在本机对应哪一档核；coalition slot 22/35/36 是否同义。只读；自带负载每阶段 3 s，总计约 15 s（D18 ≤60 s）。
// 交叉验证：同一阶段用 host_processor_info 看各 cpuN 的忙碌 tick，再按 IORegistry cpuN 的 cluster-type 分组，
// 得到「P 型簇忙碌占比」（全系统口径，含其他进程噪声），与本进程 ptime 占比对照。
// build: xcrun clang -O1 -o perflevel_split perflevel_split.c -framework IOKit -framework CoreFoundation
#include "coal.h"
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

static char ctype[256]; static int cclus[256]; static int ncpu;
static void read_topology(void) {
  memset(ctype, '?', sizeof ctype); io_iterator_t it; if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPE"), &it)) return;
  io_object_t svc; while ((svc = IOIteratorNext(it))) { io_iterator_t ch; if (!IORegistryEntryGetChildIterator(svc, kIOServicePlane, &ch)) { io_object_t c;
      while ((c = IOIteratorNext(ch))) { io_name_t nm; IORegistryEntryGetName(c, nm); int idx;
        if (!strncmp(nm, "cpu", 3) && sscanf(nm + 3, "%d", &idx) == 1 && idx < 256) {
          CFDataRef t = IORegistryEntryCreateCFProperty(c, CFSTR("cluster-type"), kCFAllocatorDefault, 0); if (t) { ctype[idx] = CFDataGetLength(t) ? (char)CFDataGetBytePtr(t)[0] : '?'; CFRelease(t); }
          CFDataRef ci = IORegistryEntryCreateCFProperty(c, CFSTR("cluster-id"), kCFAllocatorDefault, 0); if (ci) { uint32_t v = 0; CFDataGetBytes(ci, CFRangeMake(0, 4), (UInt8 *)&v); cclus[idx] = v; CFRelease(ci); } }
        IOObjectRelease(c); } IOObjectRelease(ch); } IOObjectRelease(svc); }
  IOObjectRelease(it);
}
static void cpu_ticks(uint64_t *busy, uint64_t *tot) {
  natural_t n; processor_info_array_t info; mach_msg_type_number_t cnt;
  if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt)) return; ncpu = n;
  for (natural_t i = 0; i < n; i++) { integer_t *t = info + i * CPU_STATE_MAX; busy[i] = t[CPU_STATE_USER] + t[CPU_STATE_SYSTEM] + t[CPU_STATE_NICE]; tot[i] = busy[i] + t[CPU_STATE_IDLE]; }
  vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
}

static atomic_int stop; static double sink;
static void *spin(void *a) { pthread_set_qos_class_self_np((qos_class_t)(intptr_t)a, 0); double x = 1; while (!atomic_load_explicit(&stop, memory_order_relaxed)) for (int i = 0; i < 100000; i++) x = x * 1.0000001 + 0.5; sink += x; return NULL; }

static void phase(const char *name, qos_class_t q, int n, uint64_t mycid) {
  struct rusage_info_v6 a, b; uint64_t sa[COAL_SLOTS], sb[COAL_SLOTS]; uint64_t ba[256], ta[256], bb[256], tb[256];
  rusage6(getpid(), &a); coal_cru(mycid, sa, sizeof sa); cpu_ticks(ba, ta); uint64_t t0 = now_ns();
  atomic_store(&stop, 0); pthread_t th[64]; for (int i = 0; i < n; i++) pthread_create(&th[i], NULL, spin, (void *)(intptr_t)q);
  sleep(3); atomic_store(&stop, 1); for (int i = 0; i < n; i++) pthread_join(th[i], NULL);
  rusage6(getpid(), &b); coal_cru(mycid, sb, sizeof sb); cpu_ticks(bb, tb); double dt = (now_ns() - t0) / 1e9; double k = tick_to_ns() / 1e9;
  double tot = ((b.ri_user_time - a.ri_user_time) + (b.ri_system_time - a.ri_system_time)) * k;
  double pt = ((b.ri_user_ptime - a.ri_user_ptime) + (b.ri_system_ptime - a.ri_system_ptime)) * k;
  double cyc = b.ri_cycles - a.ri_cycles, pcyc = b.ri_pcycles - a.ri_pcycles, ins = b.ri_instructions - a.ri_instructions, pins = b.ri_pinstructions - a.ri_pinstructions;
  double e = (b.ri_energy_nj - a.ri_energy_nj) / 1e9, pe = (b.ri_penergy_nj - a.ri_penergy_nj) / 1e9;
  double ctot = (coal_cpu_ticks(sb) - coal_cpu_ticks(sa)) * k, cpt = (sb[22] - sa[22]) * k, ce = (sb[11] - sa[11]) / 1e9;
  // 系统口径：各 cluster-type 的忙碌 tick
  char types[16] = ""; double busyT[16] = {0}; int ntypes = 0, cores[16] = {0}; double allbusy = 0;
  for (int i = 0; i < ncpu; i++) { int ti = -1; for (int j = 0; j < ntypes; j++) if (types[j] == ctype[i]) ti = j; if (ti < 0) { ti = ntypes++; types[ti] = ctype[i]; }
    double d = (double)(bb[i] - ba[i]); busyT[ti] += d; allbusy += d; cores[ti]++; }
  printf("%-26s thr=%-2d wall=%.2fs | proc cpu=%.2fs ptime=%.2fs share=%.1f%% | f_p=%.0f MHz f_nonp=%.0f MHz | IPC_p=%.2f | E=%.2fJ (%.2fW) pE=%.2fJ (%.0f%%) | coalition d(eqos)=%.2fs d(slot22)=%.2fs share=%.1f%% dE=%.2fJ |",
         name, n, dt, tot, pt, tot > 0 ? 100 * pt / tot : 0, pt > 0 ? pcyc / pt / 1e6 : 0, tot - pt > 0.01 ? (cyc - pcyc) / (tot - pt) / 1e6 : 0, pcyc > 0 ? pins / pcyc : 0,
         e, e / dt, pe, e > 0 ? 100 * pe / e : 0, ctot, cpt, ctot > 0 ? 100 * cpt / ctot : 0, ce);
  for (int j = 0; j < ntypes; j++) printf(" sys busy on type %c (%d cores): %.1f%% of busy, %.0f%% util;", types[j], cores[j], allbusy > 0 ? 100 * busyT[j] / allbusy : 0, 100 * busyT[j] / (dt * 100 * cores[j]));
  printf("\n"); (void)ins;
}

int main(void) {
  print_machine(); coal_init(); read_topology(); uint64_t b[256], t[256]; cpu_ticks(b, t);
  printf("# IORegistry cpuN cluster-type/cluster-id:"); for (int i = 0; i < ncpu; i++) printf(" cpu%d=%c/%d", i, ctype[i], cclus[i]); printf("\n");
  int p0 = 0; size_t sz = sizeof p0; sysctlbyname("hw.perflevel0.logicalcpu", &p0, &sz, NULL, 0);
  uint64_t mycid = coal_of_pid(getpid());
  printf("# f_p = d(ri_pcycles)/d(ptime), f_nonp = (d cycles - d pcycles)/(d time - d ptime); pE = ri_penergy_nj\n");
  phase("USER_INTERACTIVE x2", QOS_CLASS_USER_INTERACTIVE, 2, mycid);
  phase("BACKGROUND x2", QOS_CLASS_BACKGROUND, 2, mycid);
  phase("UTILITY x2", QOS_CLASS_UTILITY, 2, mycid);
  phase("USER_INTERACTIVE x(p0+2)", QOS_CLASS_USER_INTERACTIVE, p0 + 2, mycid);
  phase("DEFAULT x ncpu", QOS_CLASS_DEFAULT, ncpu, mycid);
  return 0;
}
