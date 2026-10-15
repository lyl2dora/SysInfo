// coal.h - CPU 模块「进程 Top N」调研探针的公共头（只读）。
// 私有符号全部 dlsym 解析：proc_listcoalitions、coalition_info_pid_list（27 新增 flavor 5）、coalition_info_resource_usage。
// 另有 responsibility_get_pid_responsible_for_pid（libquarantine，私有）。
// 用法：#include "coal.h"，先调 coal_init()。
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

#define COAL_SLOTS 50            // 27.0 (26A428) 实测 400 字节；公开 xnu-12377 为 45 槽 / 360 字节
#define COAL_BUF_SLOTS 64        // 调用时给 512 字节，靠「被覆写字节数」探测真实大小

typedef int (*coal_cru_fn)(uint64_t cid, void *buf, size_t size);
typedef int (*coal_pl_fn)(uint64_t cid, void *pids, size_t *size);
typedef int (*coal_lc_fn)(int flavor, int type, void *buf, int bufsize);
typedef pid_t (*resp_fn)(pid_t pid);

struct coal_listent { uint64_t cid; uint32_t type; uint32_t tasks; };   // proc_listcoalitions(2, 0) 每项 16 字节
struct coal_pidinfo { uint64_t coalition_id[2]; uint64_t r1, r2, r3; };   // PROC_PIDCOALITIONINFO (20)

static coal_cru_fn coal_cru;
static coal_pl_fn coal_pl;
static coal_lc_fn coal_lc;
static resp_fn coal_resp;

static inline int coal_init(void) {
  coal_cru = (coal_cru_fn)dlsym(RTLD_DEFAULT, "coalition_info_resource_usage");
  coal_pl = (coal_pl_fn)dlsym(RTLD_DEFAULT, "coalition_info_pid_list");
  coal_lc = (coal_lc_fn)dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  coal_resp = (resp_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
  return coal_cru && coal_pl && coal_lc;
}

static inline uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static inline uint64_t thread_cpu_ns(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
static inline uint64_t proc_cpu_ns(void) { return clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID); }

static inline double tick_to_ns(void) {
  static double k = 0; if (k == 0) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); k = (double)tb.numer / tb.denom; } return k;
}

// 列出全部 resource coalition；返回条数。*out 由调用方 free。
static inline int coal_list(struct coal_listent **out) {
  int bytes = coal_lc(2, 0, NULL, 0);
  if (bytes <= 0) { *out = NULL; return 0; }
  int cap = bytes + 64 * (int)sizeof(struct coal_listent);  // 两次调用之间可能新建 coalition，留余量
  struct coal_listent *ci = malloc(cap);
  bytes = coal_lc(2, 0, ci, cap);
  *out = ci; return bytes > 0 ? bytes / (int)sizeof *ci : 0;
}

// 本进程所在的 resource coalition id
static inline uint64_t coal_of_pid(pid_t pid) {
  struct coal_pidinfo pc = {0};
  if (proc_pidinfo(pid, 20, 0, &pc, sizeof pc) <= 0) return 0;
  return pc.coalition_id[0];
}

// CPU 时间（mach tick）= eqos 槽 24..30 之和
static inline uint64_t coal_cpu_ticks(const uint64_t *s) { uint64_t t = 0; for (int q = 24; q <= 30; q++) t += s[q]; return t; }

static inline int shortinfo(pid_t pid, struct proc_bsdshortinfo *si) {
  return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, si, sizeof *si) == (int)sizeof *si;
}

static inline int rusage6(pid_t pid, struct rusage_info_v6 *ri) {
  return proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)ri) == 0;
}

static int cmp_double(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static inline double median(double *v, int n) { if (n <= 0) return 0; qsort(v, n, sizeof *v, cmp_double); return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2; }
static inline double pct(double *v, int n, double p) { if (n <= 0) return 0; qsort(v, n, sizeof *v, cmp_double); int i = (int)(p * (n - 1) + 0.5); return v[i]; }

static inline void print_machine(void) {
  char model[64] = "", brand[128] = "", os[64] = ""; size_t sz;
  sz = sizeof model; sysctlbyname("hw.model", model, &sz, NULL, 0);
  sz = sizeof brand; sysctlbyname("machdep.cpu.brand_string", brand, &sz, NULL, 0);
  sz = sizeof os; sysctlbyname("kern.osversion", os, &sz, NULL, 0);
  int nl = 0; sz = sizeof nl; sysctlbyname("hw.nperflevels", &nl, &sz, NULL, 0);
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  printf("# machine: %s / %s / build %s / timebase %u/%u / nperflevels %d:", model, brand, os, tb.numer, tb.denom, nl);
  for (int i = 0; i < nl; i++) { char k[64], name[64] = ""; int n = 0; snprintf(k, sizeof k, "hw.perflevel%d.name", i); sz = sizeof name; sysctlbyname(k, name, &sz, NULL, 0);
    snprintf(k, sizeof k, "hw.perflevel%d.logicalcpu", i); sz = sizeof n; sysctlbyname(k, &n, &sz, NULL, 0); printf(" [%d]=%s x%d", i, name, n); }
  printf("\n");
}
