// sk.h - skeptic-processes 复核探针公共头（独立实现，不复用 processes/coal.h）。只读。
// 私有符号全部 dlsym；缓冲大小运行时探测，不写死 50 槽。
#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <dlfcn.h>
#include <time.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>

typedef int (*sk_cru_t)(uint64_t, void *, size_t);
typedef int (*sk_pl_t)(uint64_t, void *, size_t *);
typedef int (*sk_lc_t)(int, int, void *, int);
static sk_cru_t sk_cru; static sk_pl_t sk_pl; static sk_lc_t sk_lc;
struct sk_ent { uint64_t cid; uint32_t type; uint32_t tasks; };
#define SKS 64   // 读缓冲 64 槽（512 B），实际写多少由 sk_probe_size 探测

static inline int sk_init(void) {
  sk_cru = (sk_cru_t)dlsym(RTLD_DEFAULT, "coalition_info_resource_usage");
  sk_pl = (sk_pl_t)dlsym(RTLD_DEFAULT, "coalition_info_pid_list");
  sk_lc = (sk_lc_t)dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  return sk_cru && sk_pl && sk_lc;
}
static inline uint64_t sk_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static inline uint64_t sk_tcpu(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
static inline uint64_t sk_pcpu(void) { return clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID); }
static inline double sk_tb(void) { static double k; if (!k) { mach_timebase_info_data_t t; mach_timebase_info(&t); k = (double)t.numer / t.denom; } return k; }
static inline uint64_t sk_eqos(const uint64_t *s) { uint64_t t = 0; for (int i = 24; i <= 30; i++) t += s[i]; return t; }
static inline int sk_list(struct sk_ent **out) {
  int need = sk_lc(2, 0, NULL, 0); if (need <= 0) { *out = NULL; return 0; }
  int cap = need + 128 * (int)sizeof(struct sk_ent); *out = malloc(cap);
  int got = sk_lc(2, 0, *out, cap); return got > 0 ? got / (int)sizeof(struct sk_ent) : 0;
}
static inline int sk_probe_size(uint64_t cid) { unsigned char b[SKS * 8]; int w = 0;
  for (int k = 0; k < 2; k++) { memset(b, k ? 0x3C : 0xC3, sizeof b); if (sk_cru(cid, b, sizeof b)) return -1; for (int i = sizeof b - 1; i >= 0; i--) if (b[i] != (k ? 0x3C : 0xC3)) { if (i + 1 > w) w = i + 1; break; } }
  return w; }
static inline uint64_t sk_cid_of(pid_t pid) { uint64_t b[8] = {0}; if (proc_pidinfo(pid, 20, 0, b, sizeof b) <= 0) return 0; return b[0]; }
static inline int sk_members(uint64_t cid, pid_t *out, int cap) { size_t sz = cap * sizeof(pid_t); if (sk_pl(cid, out, &sz)) return -1; return (int)(sz / sizeof(pid_t)); }
static inline const char *sk_name(pid_t pid, char *buf, size_t n) {
  if (pid == 0) { snprintf(buf, n, "kernel_task"); return buf; }
  char p[PROC_PIDPATHINFO_MAXSIZE]; if (proc_pidpath(pid, p, sizeof p) > 0) { const char *b = strrchr(p, '/'); snprintf(buf, n, "%s", b ? b + 1 : p); return buf; }
  struct proc_bsdshortinfo si; if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) == sizeof si) { snprintf(buf, n, "%s", si.pbsi_comm); return buf; }
  snprintf(buf, n, "?"); return buf; }
static inline void sk_machine(void) {
  char m[64] = "", b[128] = "", o[32] = ""; size_t z; z = sizeof m; sysctlbyname("hw.model", m, &z, 0, 0); z = sizeof b; sysctlbyname("machdep.cpu.brand_string", b, &z, 0, 0);
  z = sizeof o; sysctlbyname("kern.osversion", o, &z, 0, 0); double la[3]; getloadavg(la, 3);
  time_t t = time(0); char ts[32]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
  printf("# %s %s build %s, loadavg %.2f %.2f %.2f, at %s\n", m, b, o, la[0], la[1], la[2], ts); }
static int sk_cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
static inline double sk_med(double *v, int n) { if (!n) return 0; qsort(v, n, sizeof *v, sk_cmpd); return n & 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2; }
