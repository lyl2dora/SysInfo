// coalkit.c - see coalkit.h.  coalition_info_resource_usage + coalition_info_pid_list (libsystem_kernel, private),
// proc_pid_rusage(RUSAGE_INFO_V6) per member, AGXDeviceUserClient AppUsage.accumulatedGPUTime per member pid,
// IOReport "Energy Model"/"GPU Energy" (AGX, nJ) system GPU energy.
#include "coalkit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dlfcn.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
typedef int (*cru_fn)(uint64_t, void *, size_t);
typedef int (*pl_fn)(uint64_t, void *, size_t *);
static cru_fn g_cru; static pl_fn g_pl;
// IOReport (private, /usr/lib/libIOReport.dylib)
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
static IOReportSubscriptionRef g_sub2; static CFMutableDictionaryRef g_subch2; static CFDictionaryRef g_prev2;
// system GPU active time from IOReport "GPU Stats"/"GPU Performance States"/GPUPH residency (non-OFF states, 24 MHz ticks)
static double gpu_active_delta_s(void) {
  if (!g_sub2) return -1; CFDictionaryRef s = IOReportCreateSamples(g_sub2, g_subch2, NULL); double act = -1;
  if (g_prev2 && s) { CFDictionaryRef d = IOReportCreateSamplesDelta(g_prev2, s, NULL); CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) { CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i); CFStringRef n = IOReportChannelGetChannelName(c), sg = IOReportChannelGetSubGroup(c);
      if (n && sg && CFStringCompare(n, CFSTR("GPUPH"), 0) == 0 && CFStringCompare(sg, CFSTR("GPU Performance States"), 0) == 0) { int64_t a = 0;
        for (int k = 0; k < IOReportStateGetCount(c); k++) { CFStringRef sn = IOReportStateGetNameForIndex(c, k); if (sn && CFStringCompare(sn, CFSTR("OFF"), 0) != 0) a += IOReportStateGetResidency(c, k); }
        act = a / 24e6; } }
    CFRelease(d); }
  if (g_prev2) CFRelease(g_prev2); g_prev2 = s; return act;
}
static IOReportSubscriptionRef g_sub; static CFMutableDictionaryRef g_subch; static CFDictionaryRef g_prev;
static const char *SN[CK_SLOTS] = {
 "tasks_started","tasks_exited","time_nonempty","cpu_time","interrupt_wakeups","platform_idle_wakeups","bytesread","byteswritten",
 "gpu_time","cpu_time_billed_to_me","cpu_time_billed_to_others","energy","logical_immediate_writes","logical_deferred_writes",
 "logical_invalidated_writes","logical_metadata_writes","logical_immediate_writes_to_external","logical_deferred_writes_to_external",
 "logical_invalidated_writes_to_external","logical_metadata_writes_to_external","energy_billed_to_me","energy_billed_to_others",
 "cpu_ptime","cpu_time_eqos_len","eqos[0]DEFAULT","eqos[1]MAINTENANCE","eqos[2]BACKGROUND","eqos[3]UTILITY","eqos[4]LEGACY",
 "eqos[5]USER_INITIATED","eqos[6]USER_INTERACTIVE","cpu_instructions","cpu_cycles","fs_metadata_writes","pm_writes",
 "cpu_pinstructions","cpu_pcycles","conclave_mem","ane_mach_time","ane_energy_nj","phys_footprint","gpu_energy_nj",
 "gpu_energy_nj_billed_to_me","gpu_energy_nj_billed_to_others","slot44(?)","slot45(?)","slot46(?)","slot47(?)","slot48(?)","slot49=pageins" };
const char *ck_slot_name(int i) { return (i >= 0 && i < CK_SLOTS) ? SN[i] : "?"; }
int ck_init(void) {
  void *k = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW);
  g_cru = (cru_fn)dlsym(k, "coalition_info_resource_usage"); g_pl = (pl_fn)dlsym(k, "coalition_info_pid_list");
  CFDictionaryRef ch = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
  if (ch) { g_subch = NULL; CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch); CFRelease(ch);
    g_sub = IOReportCreateSubscription(NULL, m, &g_subch, 0, NULL); }
  CFDictionaryRef ch2 = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), NULL, 0, 0, 0);
  if (ch2) { CFMutableDictionaryRef m2 = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch2); CFRelease(ch2); g_sub2 = IOReportCreateSubscription(NULL, m2, &g_subch2, 0, NULL); }
  return g_cru && g_pl && g_sub;
}
uint64_t ck_self_cid(void) { uint64_t c[5] = {0}; proc_pidinfo(getpid(), 20, 0, c, sizeof c); return c[0]; }
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static double gpu_energy_delta_j(void) {
  if (!g_sub) return -1; CFDictionaryRef s = IOReportCreateSamples(g_sub, g_subch, NULL); double j = -1;
  if (g_prev && s) { CFDictionaryRef d = IOReportCreateSamplesDelta(g_prev, s, NULL);
    CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) { CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i); CFStringRef n = IOReportChannelGetChannelName(c);
      if (n && CFStringCompare(n, CFSTR("GPU Energy"), 0) == 0) j = IOReportSimpleGetIntegerValue(c, 0) / 1e9; }
    CFRelease(d); }
  if (g_prev) CFRelease(g_prev); g_prev = s; return j;
}
// AGX per-pid accumulatedGPUTime (ns) summed over user clients whose IOUserClientCreator is "pid N, ..."
static void agx_fill(ck_snap *s) {
  io_iterator_t it; if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return;
  io_object_t acc; while ((acc = IOIteratorNext(it))) { io_iterator_t kids; if (IORegistryEntryGetChildIterator(acc, kIOServicePlane, &kids) == KERN_SUCCESS) { io_object_t c;
      while ((c = IOIteratorNext(kids))) { CFStringRef cr = IORegistryEntryCreateCFProperty(c, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
        if (cr) { char b[128] = ""; CFStringGetCString(cr, b, sizeof b, kCFStringEncodingUTF8); CFRelease(cr); int pid = -1; sscanf(b, "pid %d", &pid);
          for (int i = 0; i < s->nm; i++) if (s->m[i].pid == pid) { CFArrayRef au = IORegistryEntryCreateCFProperty(c, CFSTR("AppUsage"), kCFAllocatorDefault, 0);
              if (au && CFGetTypeID(au) == CFArrayGetTypeID()) for (CFIndex k = 0; k < CFArrayGetCount(au); k++) { CFDictionaryRef d = CFArrayGetValueAtIndex(au, k);
                  CFNumberRef n = CFDictionaryGetValue(d, CFSTR("accumulatedGPUTime")); int64_t v = 0; if (n) { CFNumberGetValue(n, kCFNumberSInt64Type, &v); s->m[i].agx_ns += v; } }
              if (au) CFRelease(au); } }
        IOObjectRelease(c); } IOObjectRelease(kids); }
    IOObjectRelease(acc); }
  IOObjectRelease(it);
}
void ck_snap_take(ck_snap *s, uint64_t cid) {
  memset(s, 0, sizeof *s); s->cid = cid; s->t_ns = now_ns();
  g_cru(cid, s->s, sizeof(uint64_t) * CK_SLOTS);
  pid_t p[CK_MAXM]; size_t sz = sizeof p; if (g_pl(cid, p, &sz) == 0) s->nm = (int)(sz / sizeof(pid_t));
  for (int i = 0; i < s->nm; i++) { s->m[i].pid = p[i]; proc_name(p[i], s->m[i].name, sizeof s->m[i].name);
    s->m[i].ok = proc_pid_rusage(p[i], RUSAGE_INFO_V6, (rusage_info_t *)&s->m[i].ri) == 0; }
  agx_fill(s);
  s->gpu_energy_j_since_prev = gpu_energy_delta_j();
  s->gpu_active_s_since_prev = gpu_active_delta_s();
}
void ck_log(const char *msg) { char b[32]; time_t t = time(NULL); strftime(b, sizeof b, "%H:%M:%S", localtime(&t)); printf("[%s] %s\n", b, msg); fflush(stdout); }
#define RD(f) sum.f += (b->m[j].ri.f - (ia >= 0 ? a->m[ia].ri.f : 0))
void ck_print_delta(const char *phase, const ck_snap *a, const ck_snap *b) {
  double wall = (b->t_ns - a->t_ns) / 1e9;
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); double t2n = (double)tb.numer / tb.denom;
  printf("---- PHASE %s: wall %.3f s, cid %llu, members before=%d after=%d\n", phase, wall, b->cid, a->nm, b->nm);
  for (int i = 0; i < CK_SLOTS; i++) { uint64_t d = b->s[i] - a->s[i]; printf("   slot %2d %-40s %22llu  delta %20lld\n", i, SN[i], b->s[i], (long long)d); }
  // decomposition: sum of member rusage deltas (members present in both; new members counted fully)
  struct rusage_info_v6 sum; memset(&sum, 0, sizeof sum); uint64_t agx = 0; int unread = 0;
  for (int j = 0; j < b->nm; j++) { if (!b->m[j].ok) { unread++; continue; } int ia = -1; for (int i = 0; i < a->nm; i++) if (a->m[i].pid == b->m[j].pid && a->m[i].ok) ia = i;
    RD(ri_user_time); RD(ri_system_time); RD(ri_pkg_idle_wkups); RD(ri_interrupt_wkups); RD(ri_pageins); RD(ri_diskio_bytesread); RD(ri_diskio_byteswritten);
    RD(ri_cpu_time_qos_default); RD(ri_cpu_time_qos_maintenance); RD(ri_cpu_time_qos_background); RD(ri_cpu_time_qos_utility); RD(ri_cpu_time_qos_legacy);
    RD(ri_cpu_time_qos_user_initiated); RD(ri_cpu_time_qos_user_interactive); RD(ri_billed_system_time); RD(ri_serviced_system_time); RD(ri_logical_writes);
    RD(ri_instructions); RD(ri_cycles); RD(ri_billed_energy); RD(ri_serviced_energy); RD(ri_runnable_time); RD(ri_user_ptime); RD(ri_system_ptime);
    RD(ri_pinstructions); RD(ri_pcycles); RD(ri_energy_nj); RD(ri_penergy_nj); RD(ri_secure_time_in_system); RD(ri_page_wait_time_mach); RD(ri_page_cache_hits);
    agx += b->m[j].agx_ns - (ia >= 0 ? a->m[ia].agx_ns : 0); }
  printf("   members:"); for (int j = 0; j < b->nm; j++) printf(" %d:%s%s", b->m[j].pid, b->m[j].name, b->m[j].ok ? "" : "(rusage EPERM)"); printf("  (unreadable=%d)\n", unread);
  uint64_t ut = sum.ri_user_time + sum.ri_system_time, pt = sum.ri_user_ptime + sum.ri_system_ptime;
  printf("   rusage-sum: user+sys=%llu (%.3f s if ns | %.3f s if mach ticks)  ptime=%llu  runnable=%llu\n", ut, ut / 1e9, ut * t2n / 1e9, pt, sum.ri_runnable_time);
  printf("   rusage-sum: qos def=%llu maint=%llu bg=%llu util=%llu legacy=%llu UI=%llu UIA=%llu\n", sum.ri_cpu_time_qos_default, sum.ri_cpu_time_qos_maintenance, sum.ri_cpu_time_qos_background,
     sum.ri_cpu_time_qos_utility, sum.ri_cpu_time_qos_legacy, sum.ri_cpu_time_qos_user_initiated, sum.ri_cpu_time_qos_user_interactive);
  printf("   rusage-sum: instr=%llu cycles=%llu pinstr=%llu pcycles=%llu energy_nj=%llu penergy_nj=%llu billed_energy=%llu serviced_energy=%llu billed_sys=%llu serviced_sys=%llu\n",
     sum.ri_instructions, sum.ri_cycles, sum.ri_pinstructions, sum.ri_pcycles, sum.ri_energy_nj, sum.ri_penergy_nj, sum.ri_billed_energy, sum.ri_serviced_energy, sum.ri_billed_system_time, sum.ri_serviced_system_time);
  printf("   rusage-sum: pkg_idle_wkups=%llu interrupt_wkups=%llu diskio r=%llu w=%llu logical_writes=%llu pageins=%llu page_wait_mach=%llu page_cache_hits=%llu secure_time=%llu\n",
     sum.ri_pkg_idle_wkups, sum.ri_interrupt_wkups, sum.ri_diskio_bytesread, sum.ri_diskio_byteswritten, sum.ri_logical_writes, sum.ri_pageins, sum.ri_page_wait_time_mach, sum.ri_page_cache_hits, sum.ri_secure_time_in_system);
  printf("   AGX accumulatedGPUTime delta (members) = %llu ns (%.3f s); IOReport 'GPU Energy' (system, AGX) over phase = %.3f J (%.2f W); IOReport GPUPH non-OFF residency (system) = %.3f s\n", agx, agx / 1e9, b->gpu_energy_j_since_prev, b->gpu_energy_j_since_prev / wall, b->gpu_active_s_since_prev);
  uint64_t dcpu = b->s[3] - a->s[3];
  printf("   KEY: cpu_time d=%llu vs rusage user+sys d=%llu (ratio %.4f) | energy d=%llu nJ = %.3f J (%.2f W) vs ri_energy_nj d=%.3f J | cpu_ptime d=%llu vs ptime %llu | gpu_time d=%llu vs AGX %llu ns | gpu_energy_nj d=%llu (%.3f J) | ane_mach_time d=%llu ane_energy_nj d=%llu\n",
     dcpu, ut, ut ? (double)dcpu / ut : 0, b->s[11] - a->s[11], (b->s[11] - a->s[11]) / 1e9, (b->s[11] - a->s[11]) / 1e9 / wall, sum.ri_energy_nj / 1e9, b->s[22] - a->s[22], pt,
     b->s[8] - a->s[8], agx, b->s[41] - a->s[41], (b->s[41] - a->s[41]) / 1e9, b->s[38] - a->s[38], b->s[39] - a->s[39]);
  fflush(stdout);
}
