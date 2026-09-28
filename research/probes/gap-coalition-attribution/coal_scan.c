// coal_scan.c - (3b)/(5): full native per-app scan without root:
//   A) cost per tick of each component (wall + thread CPU), 30 iterations
//   B) attribution coverage for foreign (other-uid) pids: sole member / only-unreadable member (exact via residual) / shared
//   C) 2 s window top lists by coalition: CPU%, energy W, GPU% (slot 8) vs AGX per-pid accumulatedGPUTime, ANE%, ANE W, disk B/s
//   D) lifetime ANE users (slot 38/39) incl. foreign coalitions
// Read-only. build: xcrun clang -O1 -o coal_scan coal_scan.c -framework IOKit -framework CoreFoundation
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
typedef int (*cru_fn)(uint64_t, void *, size_t); typedef int (*pl_fn)(uint64_t, void *, size_t *); typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
static cru_fn cru; static pl_fn pl; static lc_fn lc;
#define MAXC 4096
#define MAXP 8192
typedef struct { uint64_t cid; uint64_t s[50]; int np; pid_t pid[128]; } CO;
typedef struct { int n; CO c[MAXC]; uint64_t t; } SNAP;
static SNAP A, B;
static uint64_t tcpu(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
static uint64_t wall(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void take(SNAP *S, int withpids) { S->t = wall(); int bytes = lc(2, 0, NULL, 0); static struct coalinfo ci[MAXC]; bytes = lc(2, 0, ci, sizeof ci); S->n = bytes / sizeof(struct coalinfo);
  for (int i = 0; i < S->n; i++) { S->c[i].cid = ci[i].cid; cru(ci[i].cid, S->c[i].s, sizeof S->c[i].s); if (withpids) { size_t sz = sizeof S->c[i].pid; S->c[i].np = pl(ci[i].cid, S->c[i].pid, &sz) == 0 ? (int)(sz / sizeof(pid_t)) : 0; } } }
static CO *findc(SNAP *S, uint64_t cid) { for (int i = 0; i < S->n; i++) if (S->c[i].cid == cid) return &S->c[i]; return NULL; }
// AGX per-pid GPU time
static int agx_pid[2048]; static uint64_t agx_ns[2048]; static int nagx;
static void agx_scan(void) { nagx = 0; io_iterator_t it; if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it)) return; io_object_t acc;
  while ((acc = IOIteratorNext(it))) { io_iterator_t kids; if (!IORegistryEntryGetChildIterator(acc, kIOServicePlane, &kids)) { io_object_t c; while ((c = IOIteratorNext(kids))) {
        CFStringRef cr = IORegistryEntryCreateCFProperty(c, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0); int pid = -1;
        if (cr) { char b[128] = ""; CFStringGetCString(cr, b, sizeof b, kCFStringEncodingUTF8); CFRelease(cr); sscanf(b, "pid %d", &pid); }
        CFArrayRef au = IORegistryEntryCreateCFProperty(c, CFSTR("AppUsage"), kCFAllocatorDefault, 0); uint64_t ns = 0;
        if (au && CFGetTypeID(au) == CFArrayGetTypeID()) for (CFIndex k = 0; k < CFArrayGetCount(au); k++) { CFNumberRef n = CFDictionaryGetValue(CFArrayGetValueAtIndex(au, k), CFSTR("accumulatedGPUTime")); int64_t v = 0; if (n) CFNumberGetValue(n, kCFNumberSInt64Type, &v); ns += v; }
        if (au) CFRelease(au);
        if (pid >= 0 && nagx < 2048) { int f = -1; for (int i = 0; i < nagx; i++) if (agx_pid[i] == pid) f = i; if (f < 0) { f = nagx++; agx_pid[f] = pid; agx_ns[f] = 0; } agx_ns[f] += ns; }
        IOObjectRelease(c); } IOObjectRelease(kids); } IOObjectRelease(acc); } IOObjectRelease(it); }
static uint64_t agx_get(int pid) { for (int i = 0; i < nagx; i++) if (agx_pid[i] == pid) return agx_ns[i]; return 0; }
int main(void) {
  cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double t2n = (double)tb.numer / tb.denom; uid_t me = getuid();
  // ---------- A) cost
  const int N = 30; uint64_t w0, c0; double cw[6] = {0}, cc[6] = {0};
  static pid_t pids[MAXP]; int np = 0;
  for (int it = 0; it < N; it++) {
    w0 = wall(); c0 = tcpu(); take(&A, 0); cw[0] += wall() - w0; cc[0] += tcpu() - c0;                      // coalitions list + cru
    w0 = wall(); c0 = tcpu(); take(&A, 1); cw[1] += wall() - w0; cc[1] += tcpu() - c0;                      // + pid lists
    w0 = wall(); c0 = tcpu(); np = proc_listallpids(pids, sizeof pids); int same = 0;
    for (int i = 0; i < np; i++) { struct proc_bsdshortinfo si; proc_pidinfo(pids[i], PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si); } cw[2] += wall() - w0; cc[2] += tcpu() - c0; // names/uids
    w0 = wall(); c0 = tcpu(); for (int i = 0; i < np; i++) { struct rusage_info_v6 ri; if (proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ri) == 0) same++; } cw[3] += wall() - w0; cc[3] += tcpu() - c0; // rusage all (same-uid succeed)
    w0 = wall(); c0 = tcpu(); for (int i = 0; i < np; i++) { uint64_t c[5]; proc_pidinfo(pids[i], 20, 0, c, sizeof c); } cw[4] += wall() - w0; cc[4] += tcpu() - c0; // PROC_PIDCOALITIONINFO per pid (old method)
    w0 = wall(); c0 = tcpu(); agx_scan(); cw[5] += wall() - w0; cc[5] += tcpu() - c0;
    if (it == N - 1) printf("scan sizes: coalitions=%d pids=%d same-uid rusage ok=%d AGX clients(pids)=%d\n", A.n, np, same, nagx);
  }
  const char *nm[6] = {"proc_listcoalitions + cru x all", "  ... + coalition_info_pid_list x all", "proc_listallpids + SHORTBSDINFO x all", "proc_pid_rusage(V6) x all pids", "PROC_PIDCOALITIONINFO x all pids", "AGX IORegistry AppUsage scan"};
  printf("A) cost per tick (mean of %d):\n", N); double tw = 0, tc = 0;
  for (int k = 0; k < 6; k++) { printf("   %-40s wall %7.3f ms  cpu %7.3f ms\n", nm[k], cw[k] / N / 1e6, cc[k] / N / 1e6); if (k != 0 && k != 4) { tw += cw[k]; tc += cc[k]; } }
  printf("   TOTAL typical tick (pid lists + names + same-uid rusage + AGX): wall %.2f ms, cpu %.2f ms -> %.3f %% of one core at 1 Hz, %.3f %% at 0.5 Hz\n", tw / N / 1e6, tc / N / 1e6, tc / N / 1e6 / 10, tc / N / 1e6 / 20);
  // ---------- B) coverage for foreign pids
  take(&A, 1); int foreign = 0, alone = 0, residual = 0, shared = 0;
  for (int i = 0; i < A.n; i++) { int unread = 0, fr = 0; for (int k = 0; k < A.c[i].np; k++) { struct rusage_info_v6 ri; struct proc_bsdshortinfo si;
      if (proc_pidinfo(A.c[i].pid[k], PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) != sizeof si) continue; if (si.pbsi_uid != me) fr++; if (proc_pid_rusage(A.c[i].pid[k], RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) unread++; }
    foreign += fr; if (!fr) continue; if (A.c[i].np == 1) alone += fr; else if (unread == 1) residual += fr; else shared += fr; }
  printf("B) foreign pids=%d: sole member of coalition=%d; only unreadable member of a mixed coalition (exact by residual: coalition minus same-uid rusage)=%d; share coalition with other unreadable pids (group-level only)=%d\n", foreign, alone, residual, shared);
  // ---------- C) 2 s window
  agx_scan(); static int ap[2048]; static uint64_t an[2048]; int na = nagx; memcpy(ap, agx_pid, sizeof ap); memcpy(an, agx_ns, sizeof an);
  take(&A, 1); sleep(2); take(&B, 1); agx_scan(); double dt = (B.t - A.t) / 1e9;
  printf("C) window %.3f s. Coalitions with activity (showing CPU>=1%% or GPU>0 or ANE>0 or disk>0):\n", dt);
  printf("   %-6s %-26s %-5s %3s %7s %8s %7s %8s %7s %8s %10s %10s\n", "cid", "lead member", "uid", "n", "CPU%", "energyW", "GPU%", "AGX%", "ANE%", "ANE_W", "diskR B/s", "diskW B/s");
  for (int i = 0; i < B.n; i++) { CO *b = &B.c[i]; CO *a = findc(&A, b->cid); if (!a) continue;
    double cpu = (b->s[3] - a->s[3]) * t2n / 1e9 / dt * 100, ew = (b->s[11] - a->s[11]) / 1e9 / dt, gpu = (b->s[8] - a->s[8]) / 1e9 / dt * 100;
    double ane = (b->s[38] - a->s[38]) * t2n / 1e9 / dt * 100, anew = (b->s[39] - a->s[39]) / 1e9 / dt, dr = (b->s[6] - a->s[6]) / dt, dw = (b->s[7] - a->s[7]) / dt;
    uint64_t agxd = 0; for (int k = 0; k < b->np; k++) { uint64_t before = 0; for (int j = 0; j < na; j++) if (ap[j] == b->pid[k]) before = an[j]; uint64_t after = agx_get(b->pid[k]); if (after >= before) agxd += after - before; }
    double agx = agxd / 1e9 / dt * 100;
    if (cpu < 1 && gpu <= 0 && agx <= 0 && ane <= 0 && dr + dw <= 0) continue;
    char name[64] = "?"; int uid = -1; for (int k = 0; k < b->np; k++) { struct proc_bsdshortinfo si; if (proc_pidinfo(b->pid[k], PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) == sizeof si) { if (uid < 0 || si.pbsi_uid == 0) { uid = si.pbsi_uid; strncpy(name, si.pbsi_comm, 63); } } }
    printf("   %-6llu %-26.26s %-5d %3d %7.2f %8.4f %7.2f %8.2f %7.2f %8.4f %10.0f %10.0f\n", b->cid, name, uid, b->np, cpu, ew, gpu, agx, ane, anew, dr, dw); }
  // ---------- D) lifetime ANE users
  printf("D) coalitions with lifetime ane_mach_time > 0:\n");
  for (int i = 0; i < B.n; i++) { CO *b = &B.c[i]; if (!b->s[38]) continue; char name[64] = "(no live members)"; int uid = -1;
    for (int k = 0; k < b->np; k++) { struct proc_bsdshortinfo si; if (proc_pidinfo(b->pid[k], PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) == sizeof si) { uid = si.pbsi_uid; strncpy(name, si.pbsi_comm, 63); break; } }
    printf("   cid %-6llu %-24.24s uid %-4d members %-3d ane_mach_time %.3f s  ane_energy %.3f J  (cpu %.1f s, gpu %.1f s)\n", b->cid, name, uid, b->np, b->s[38] * t2n / 1e9, b->s[39] / 1e9, b->s[3] * t2n / 1e9, b->s[8] / 1e9); }
  return 0; }
