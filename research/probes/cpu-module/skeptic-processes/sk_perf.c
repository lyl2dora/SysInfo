// sk_perf.c - 复核「rusage/coalition 的 p 桶 = perflevel0 = IORegistry cluster-type 'P'」以及对方提出的发现算法与频率签名自检。
// 与对方不同的验证方法：用 hw.logicalcpu 个 UI 线程把全部核跑满，p 桶占比应 ≈ #P核 / 总核数（M5 应 ≈6/18=33%，M2 ≈8/12=67%）；
// 若 p 把 M5 的 perflevel1（cluster-type M）也算进去，占比会接近 100%。再测单线程 utility / background，以及 20 次 50 ms UI 自旋的自检稳定性。
// 用法：sk_perf [自检自旋毫秒]（给参数时只跑 20 次自检）。负载：满核 3 s；单线程 utility 2 s、background 2 s；UI 50 ms × 20。总计约 10 s。用法：sk_perf    build: xcrun clang -O1 -framework IOKit -framework CoreFoundation -o sk_perf sk_perf.c
#include "sk.h"
#include <pthread.h>
#include <pthread/qos.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
static volatile int go, stop; static qos_class_t Q;
static void *spin(void *a) { (void)a; pthread_set_qos_class_self_np(Q, 0); while (!go) ; volatile double x = 1; while (!stop) x = x * 1.0000001 + 0.5; return 0; }
typedef struct { double t, pt, cyc, pcyc; } U;
static U usage(void) { struct rusage_info_v6 r; proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r); double k = sk_tb();
  U u = {(r.ri_user_time + r.ri_system_time) * k, (r.ri_user_ptime + r.ri_system_ptime) * k, (double)r.ri_cycles, (double)r.ri_pcycles}; return u; }
static void report(const char *name, U a, U b, double expect) {
  double t = b.t - a.t, pt = b.pt - a.pt, c = b.cyc - a.cyc, pc = b.pcyc - a.pcyc;
  printf("   %-34s cpu %8.1f ms  p-share %5.1f%%%s  f_p %5.0f MHz  f_nonp %5.0f MHz\n", name, t / 1e6, t ? 100 * pt / t : 0, expect >= 0 ? "" : "", pt > 0 ? pc / pt * 1e3 : 0, t - pt > 0 ? (c - pc) / (t - pt) * 1e3 : 0);
  if (expect >= 0) printf("      expected p-share if p == cluster-type P only: %.1f%%\n", expect); }
static void load(int n, qos_class_t q, double secs, const char *name, double expect) {
  Q = q; go = stop = 0; pthread_t th[64]; for (int i = 0; i < n; i++) pthread_create(&th[i], 0, spin, 0); usleep(20000);
  U a = usage(); go = 1; usleep((useconds_t)(secs * 1e6)); U b = usage(); stop = 1; for (int i = 0; i < n; i++) pthread_join(th[i], 0);
  // 注意：a/b 含启动与收尾之外的主线程时间可忽略（主线程在 usleep）
  report(name, a, b, expect); }
int main(int argc, char **argv) {
  int only_ms = argc > 1 ? atoi(argv[1]) : 0;  // 给参数时只跑自检：20 次 only_ms 毫秒的 UI 单线程自旋
  sk_machine(); int nl = 0, ncpu = 0; size_t z = sizeof nl; sysctlbyname("hw.nperflevels", &nl, &z, 0, 0); z = sizeof ncpu; sysctlbyname("hw.logicalcpu", &ncpu, &z, 0, 0);
  int pl[8] = {0}; char pn[8][32]; for (int i = 0; i < nl && i < 8; i++) { char k[64]; snprintf(k, sizeof k, "hw.perflevel%d.logicalcpu", i); z = sizeof pl[i]; sysctlbyname(k, &pl[i], &z, 0, 0);
    snprintf(k, sizeof k, "hw.perflevel%d.name", i); z = sizeof pn[i]; pn[i][0] = 0; sysctlbyname(k, pn[i], &z, 0, 0); }
  // IORegistry：IODeviceTree:/cpus 下每个 cpu 的 cluster-type
  int cnt[128] = {0}; io_registry_entry_t cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus"); io_iterator_t it;
  if (cpus && IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &it) == KERN_SUCCESS) { io_object_t c;
    while ((c = IOIteratorNext(it))) { CFTypeRef v = IORegistryEntryCreateCFProperty(c, CFSTR("cluster-type"), kCFAllocatorDefault, 0);
      if (v && CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength(v) > 0) cnt[CFDataGetBytePtr(v)[0] & 127]++; if (v) CFRelease(v); IOObjectRelease(c); } IOObjectRelease(it); }
  printf("hw.logicalcpu %d, nperflevels %d:", ncpu, nl); for (int i = 0; i < nl; i++) printf(" [%d] %s x%d", i, pn[i], pl[i]); printf("; IORegistry cluster-type counts:");
  for (int c = 0; c < 128; c++) if (cnt[c]) printf(" '%c' x%d", c, cnt[c]); printf("\n");
  int rule = nl == 2 && cnt['P'] == pl[0]; printf("other agent's discovery rule (nperflevels==2 && #cluster-type P == perflevel0.logicalcpu) -> %s; label would be \"%s\"\n", rule ? "SHOW split" : "HIDE split", rule ? pn[0] : "-");
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  if (!only_ms) {
  load(ncpu, QOS_CLASS_USER_INTERACTIVE, 3, "all-core UI saturation (3 s)", 100.0 * cnt['P'] / ncpu);
  load(1, QOS_CLASS_UTILITY, 2, "1 x utility (2 s)", -1);
  load(1, QOS_CLASS_BACKGROUND, 2, "1 x background (2 s)", -1);
  }
  int sp = only_ms ? only_ms : 50; double la[3]; getloadavg(la, 3);
  printf("   frequency-signature self-check: 20 x %d ms single UI-thread spin (loadavg %.2f)\n", sp, la[0]);
  double sh[20], fp[20]; int onp = 0; for (int i = 0; i < 20; i++) { Q = QOS_CLASS_USER_INTERACTIVE; go = stop = 0; pthread_t th; pthread_create(&th, 0, spin, 0); usleep(2000);
    U a = usage(); go = 1; usleep(sp * 1000); U b = usage(); stop = 1; pthread_join(th, 0); double t = b.t - a.t, pt = b.pt - a.pt; sh[i] = t ? 100 * pt / t : 0; fp[i] = pt > 0 ? (b.pcyc - a.pcyc) / pt * 1e3 : 0; onp += sh[i] > 90; usleep(100000); }
  printf("      trials with p-share > 90%%: %d/20; p-share min %.0f%% median %.0f%%; f_p min %.0f median %.0f max %.0f MHz\n", onp, sk_med(sh, 20) * 0 + sh[0] * 0 + ({ double m = 1e9; for (int i = 0; i < 20; i++) if (sh[i] < m) m = sh[i]; m; }), sk_med(sh, 20),
         ({ double m = 1e9; for (int i = 0; i < 20; i++) if (fp[i] > 0 && fp[i] < m) m = fp[i]; m; }), sk_med(fp, 20), ({ double m = 0; for (int i = 0; i < 20; i++) if (fp[i] > m) m = fp[i]; m; }));
  return 0; }
