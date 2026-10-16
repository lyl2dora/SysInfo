// gpu_watch.c - GPU 与加速器模块边界复核：1 Hz 只读记录器（M5 Pro / M4 Pro）。
// 每秒一行 CSV（<prefix>.csv），并记录每段读取的线程 CPU 耗时（真实节奏开销）：
//   gpuph : GPU Stats「GPU Performance States」GPUPH 单通道订阅 → 活跃率、平均活跃档位、各档驻留；
//   gpuext: GPU Stats 其他状态通道（BSTGPUPH / GPU_SW / GPU_CLTM / PWRCTRL / PZRSDNCY / GPUDVDH / GPU_PPM）、
//           Temperature 计数（M4 有）、「GPU UT AggD Stats」的 Sum / Count；
//   energy: Energy Model 中 AGX「GPU Energy」单通道 → GPU 功率；
//   pmgr  : Energy Model 中 PMGR 的 GPU/ANE/AVE/AFR/MSR/ISP 顶层通道（批次检测，变化时写 <prefix>_pmgr.txt）；
//   irq   : 中断统计 ave0/avd0/apr0/ane0/jpeg/scaler 的一级中断次数（每秒）；
//   pmp   : PMP(0)「AF BW」中 AGX/ANE/AVE/AVD 的 RD+WR 与「SOC-NI Util BW」中 ANE/AVE 通道 → 加权档位（相对量）；
//   smc   : 全部 Tg* / Ta* 键（原值另写 <prefix>_temps.csv）；
//   coal  : 全部 coalition 的槽位 8（gpu_time ns）/ 41（gpu_energy nJ）/ 38（ane_mach_time）/ 39（ane_energy nJ）合计差分；
//   ioreg : H11ANEIn 的 IOPowerManagement.CurrentPowerState；AGX PerformanceStatistics 的内存与 Device Utilization %。
// 只读：SMC 只用 selector 2 的读命令（5/8/9）；只结束自己派生的进程（这里不派生任何进程）。
// build: xcrun clang -O2 -o gpu_watch gpu_watch.c -lIOReport -framework IOKit -framework CoreFoundation
// usage: gpu_watch <outprefix> <duration_s> [interval_s]
#include "ior.h"
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);

static double wall(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static double mono(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static double tcpu(void) { struct timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return t.tv_sec + t.tv_nsec / 1e9; }

// ---------- IOReport 订阅（按过滤函数挑通道） ----------
typedef int (*chan_filter)(const char *group, const char *subgroup, const char *name, const char *driver);
typedef struct { IOReportSubscriptionRef sub; CFMutableDictionaryRef subbed; CFDictionaryRef prev; int nch; } Sub;

static int make_sub(Sub *s, const char *group, chan_filter f) {
    memset(s, 0, sizeof *s);
    CFStringRef g = group ? CFStringCreateWithCString(NULL, group, kCFStringEncodingUTF8) : NULL;
    CFDictionaryRef ch = g ? IOReportCopyChannelsInGroup(g, NULL, 0, 0, 0) : IOReportCopyAllChannels(0, 0);
    if (g) CFRelease(g);
    if (!ch) return -1;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, ch);
    CFRelease(ch);
    CFArrayRef arr = CFDictionaryGetValue(m, CFSTR("IOReportChannels"));
    CFMutableArrayRef keep = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(arr, i);
        char gg[96], sg[128], nm[128], dv[128];
        cs(IOReportChannelGetGroup(c), gg, sizeof gg); cs(IOReportChannelGetSubGroup(c), sg, sizeof sg);
        cs(IOReportChannelGetChannelName(c), nm, sizeof nm); cs(IOReportChannelGetDriverName(c), dv, sizeof dv);
        if (f(gg, sg, nm, dv)) CFArrayAppendValue(keep, c);
    }
    s->nch = (int)CFArrayGetCount(keep);
    CFDictionarySetValue(m, CFSTR("IOReportChannels"), keep);
    CFRelease(keep);
    if (s->nch == 0) { CFRelease(m); return -2; }
    s->sub = IOReportCreateSubscription(NULL, m, &s->subbed, 0, NULL);
    CFRelease(m);
    if (!s->sub) return -3;
    s->prev = IOReportCreateSamples(s->sub, s->subbed, NULL);
    return 0;
}
// 返回本次与上次的差分（调用者 CFRelease），失败为 NULL。
static CFArrayRef sub_delta(Sub *s, CFDictionaryRef *holder) {
    *holder = NULL;
    if (!s->sub) return NULL;
    CFDictionaryRef cur = IOReportCreateSamples(s->sub, s->subbed, NULL);
    if (!cur) return NULL;
    CFDictionaryRef d = s->prev ? IOReportCreateSamplesDelta(s->prev, cur, NULL) : NULL;
    if (s->prev) CFRelease(s->prev);
    s->prev = cur;
    if (!d) return NULL;
    *holder = d;
    return CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
}
static int streq(const char *a, const char *b) { return strcmp(a, b) == 0; }
static int startswith(const char *a, const char *p) { return strncmp(a, p, strlen(p)) == 0; }

static int f_gpuph(const char *g, const char *sg, const char *nm, const char *dv) { (void)g; (void)sg; (void)dv; return streq(nm, "GPUPH"); }
static int f_gpuext(const char *g, const char *sg, const char *nm, const char *dv) {
    (void)dv;
    if (streq(g, "GPU Stats")) {
        static const char *names[] = {"BSTGPUPH", "GPU_SW", "GPU_CLTM", "PWRCTRL", "PZRSDNCY", "GPUDVDH", "GPU_PPM", NULL};
        for (int i = 0; names[i]; i++) if (streq(nm, names[i])) return 1;
        if (streq(sg, "Temperature")) return 1;
        return 0;
    }
    if (streq(g, "GPU UT AggD Stats")) return streq(sg, "Sum") || streq(sg, "Count");
    return 0;
}
static int f_energy(const char *g, const char *sg, const char *nm, const char *dv) { (void)g; (void)sg; return streq(nm, "GPU Energy") && startswith(dv, "AGX"); }
static int f_pmgr(const char *g, const char *sg, const char *nm, const char *dv) {
    (void)g; (void)sg;
    if (!strstr(dv, "PMGR")) return 0;
    static const char *pre[] = {"GPU", "ANE", "AVE", "AFR", "MSR", "ISP", "CPU Energy", NULL};
    for (int i = 0; pre[i]; i++) if (startswith(nm, pre[i])) return 1;
    return 0;
}
static int irq_with_ane = 1;
static int f_irq(const char *g, const char *sg, const char *nm, const char *dv) {
    (void)dv;
    if (!strstr(g, "Interrupt")) return 0;
    if (!strstr(nm, "First Level Interrupt Handler Count")) return 0;
    static const char *pre[] = {"ave0", "avd0", "apr0", "apr1", "jpeg0", "jpeg1", "scaler0", "scaler1", "ane0", NULL};
    for (int i = 0; pre[i]; i++) {
        if (!irq_with_ane && streq(pre[i], "ane0")) continue;
        if (startswith(sg, pre[i]) && sg[strlen(pre[i])] == ' ') return 1;
    }
    return 0;
}
static int f_pmp(const char *g, const char *sg, const char *nm, const char *dv) {
    (void)dv;
    if (!startswith(g, "PMP")) return 0;
    if (streq(sg, "AF BW")) {
        if (!strstr(nm, "RD+WR")) return 0;
        return startswith(nm, "AGX") || startswith(nm, "ANE") || startswith(nm, "AVE") || startswith(nm, "AVD");
    }
    if (streq(sg, "SOC-NI Util BW")) return strstr(nm, "ANE") || strstr(nm, "AVE");
    return 0;
}

// ---------- SMC（只读） ----------
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t smc;
static void s4(uint32_t k, char *o) { o[0] = k >> 24; o[1] = k >> 16; o[2] = k >> 8; o[3] = k; o[4] = 0; }
static uint32_t k4(const char *s) { return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3]; }
static int smc_call(SMCParam *in, SMCParam *out) {
    if (in->data8 != 5 && in->data8 != 8 && in->data8 != 9) return -1;  // 只允许读命令
    size_t sz = sizeof(SMCParam);
    return IOConnectCallStructMethod(smc, 2, in, sizeof(SMCParam), out, &sz) == KERN_SUCCESS ? 0 : -1;
}
static int smc_readf(uint32_t key, float *f) {
    SMCParam in = {0}, out = {0}; in.key = key; in.keyInfo.dataSize = 4; in.data8 = 5;
    if (smc_call(&in, &out) || out.result) return -1;
    memcpy(f, out.bytes, 4); return 0;
}
#define MAXT 128
static uint32_t tkeys[MAXT]; static int ntk;

// ---------- coalition ----------
typedef struct { uint64_t id; uint32_t type; uint32_t tasks; } coal_entry;
typedef int (*coal_list_fn)(int, int, void *, int);
typedef int (*coal_usage_fn)(uint64_t, void *, size_t);
static coal_list_fn cl; static coal_usage_fn cu;
#define MAXC 4096
typedef struct { uint64_t id; uint64_t s8, s41, s38, s39; int seen; } CoalPrev;
static CoalPrev cprev[MAXC]; static int ncprev;
static CoalPrev *cfind(uint64_t id) {
    for (int i = 0; i < ncprev; i++) if (cprev[i].id == id) return &cprev[i];
    if (ncprev >= MAXC) return NULL;
    CoalPrev *p = &cprev[ncprev++]; memset(p, 0, sizeof *p); p->id = id; return p;
}

// ---------- IORegistry ----------
static long long cf_int(CFTypeRef v) { long long x = -1; if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberSInt64Type, &x); return x; }
static long long dict_int(CFDictionaryRef d, const char *k) {
    if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) return -1;
    CFStringRef ks = CFStringCreateWithCString(NULL, k, kCFStringEncodingUTF8);
    long long v = cf_int(CFDictionaryGetValue(d, ks)); CFRelease(ks); return v;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: gpu_watch <outprefix> <duration_s> [interval_s]\n"); return 1; }
    const char *pre = argv[1]; double dur = atof(argv[2]); double ival = argc > 3 ? atof(argv[3]) : 1.0;
    char fn[1024];
    snprintf(fn, sizeof fn, "%s.csv", pre); FILE *fo = fopen(fn, "w");
    snprintf(fn, sizeof fn, "%s_pmgr.txt", pre); FILE *fp = fopen(fn, "w");
    snprintf(fn, sizeof fn, "%s_temps.csv", pre); FILE *ft = fopen(fn, "w");
    snprintf(fn, sizeof fn, "%s_setup.txt", pre); FILE *fsu = fopen(fn, "w");
    if (!fo || !fp || !ft || !fsu) { fprintf(stderr, "open output failed\n"); return 2; }

    // 订阅：每个分段单独建，用来分别计开销
    Sub sGPUPH, sExt, sEn, sPM, sIRQ, sPMP;
    double c0 = tcpu();
    int rc1 = make_sub(&sGPUPH, "GPU Stats", f_gpuph);
    double c1 = tcpu();
    int rc2 = make_sub(&sExt, NULL, f_gpuext);
    double c2 = tcpu();
    int rc3 = make_sub(&sEn, "Energy Model", f_energy);
    int rc4 = make_sub(&sPM, "Energy Model", f_pmgr);
    double c3 = tcpu();
    int rc5 = make_sub(&sIRQ, NULL, f_irq);
    if (rc5 == -3) { irq_with_ane = 0; rc5 = make_sub(&sIRQ, NULL, f_irq); fprintf(fsu, "irq: subscription with ane0 failed; retried without ane0 -> rc=%d\n", rc5); }
    double c4 = tcpu();
    int rc6 = make_sub(&sPMP, NULL, f_pmp);
    double c5 = tcpu();
    fprintf(fsu, "subs rc gpuph=%d(%d ch, %.1f ms) gpuext=%d(%d ch, %.1f ms) energy=%d(%d) pmgr=%d(%d) (%.1f ms) irq=%d(%d ch, ane0=%d, %.1f ms) pmp=%d(%d ch, %.1f ms)\n",
            rc1, sGPUPH.nch, (c1 - c0) * 1e3, rc2, sExt.nch, (c2 - c1) * 1e3, rc3, sEn.nch, rc4, sPM.nch, (c3 - c2) * 1e3, rc5, sIRQ.nch, irq_with_ane,
            (c4 - c3) * 1e3, rc6, sPMP.nch, (c5 - c4) * 1e3);

    // SMC
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!s || IOServiceOpen(s, mach_task_self(), 0, &smc) != KERN_SUCCESS) { fprintf(stderr, "SMC open failed\n"); return 3; }
    IOObjectRelease(s);
    {
        SMCParam in = {0}, out = {0}; in.key = k4("#KEY"); in.keyInfo.dataSize = 4; in.data8 = 5; smc_call(&in, &out);
        int cnt = (int)((uint32_t)out.bytes[0] << 24 | out.bytes[1] << 16 | out.bytes[2] << 8 | out.bytes[3]);
        for (int i = 0; i < cnt && ntk < MAXT; i++) {
            SMCParam a = {0}, b = {0}; a.data8 = 8; a.data32 = i;
            if (smc_call(&a, &b)) continue;
            char nm[5]; s4(b.key, nm);
            if (nm[0] != 'T' || (nm[1] != 'g' && nm[1] != 'a')) continue;
            SMCParam c = {0}, d = {0}; c.key = b.key; c.data8 = 9;
            if (smc_call(&c, &d) || d.result || d.keyInfo.dataSize != 4) continue;
            char t[5]; s4(d.keyInfo.dataType, t);
            if (strcmp(t, "flt ")) continue;
            tkeys[ntk++] = b.key;
        }
        fprintf(ft, "epoch");
        for (int i = 0; i < ntk; i++) { char nm[5]; s4(tkeys[i], nm); fprintf(ft, ",%s", nm); }
        fprintf(ft, "\n");
        fprintf(fsu, "smc Tg/Ta flt keys: %d\n", ntk);
    }
    // coalition
    cl = dlsym(RTLD_DEFAULT, "proc_listcoalitions"); cu = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage");
    // IORegistry
    io_service_t ane = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("H11ANEIn"));
    io_service_t agx = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    fprintf(fsu, "ane service=%s agx service=%s\n", ane ? "yes" : "no", agx ? "yes" : "no");
    fclose(fsu);

    fprintf(fo, "epoch,dt,cpu_gpuph_ms,cpu_gpuext_ms,cpu_energy_ms,cpu_pmgr_ms,cpu_irq_ms,cpu_pmp_ms,cpu_smc_ms,cpu_coal_ms,cpu_ioreg_ms,"
                "gpuph_active,gpuph_avgstate,gpuph_states,bst_active,bst_avgstate,sw_active,sw_avgstate,cltm_limited,pwrctrl_top,pzr_zoned,dvdh_mean,dvdh_mean_active,ppm_mean,"
                "ut_sum,ut_count,temp_avg_sum,temp_avg_count,temp_max,"
                "gpu_w,pmgr_changed,pmgr_GPU_mJ,pmgr_ANE_mJ,pmgr_AVE_mJ,"
                "irq_ave,irq_avd,irq_apr,irq_jpeg,irq_scaler,irq_ane,"
                "pmp_agx,pmp_ane,pmp_ave,pmp_avd,ni_ane,ni_ave,"
                "tg_max,tg_n,ta_max,ta_n,"
                "coal_gpu_busy,coal_gpu_w,coal_ane_busy,coal_ane_w,coal_top_gpu_cid,coal_top_gpu_busy,"
                "ane_ps,gpu_inuse_mb,gpu_alloc_mb,dev_util\n");

    double t0 = wall(), mPrev = mono(); double next = floor(t0) + 1.0; long n = 0; int first = 1;
    long long pmgrPrev[64]; char pmgrName[64][48]; int npmgr = 0;
    while (1) {
        double now = wall(); if (now < next) usleep((useconds_t)((next - now) * 1e6));
        double t = wall(); if (t - t0 > dur) break;
        next += ival; if (next < wall()) next = floor(wall()) + ival;
        double m = mono(), dt = m - mPrev; mPrev = m;
        double ct[10]; ct[0] = tcpu();
        CFDictionaryRef h;

        // gpuph
        double ph_active = NAN, ph_avg = NAN; char states[256] = "";
        CFArrayRef a = sub_delta(&sGPUPH, &h);
        for (CFIndex i = 0; a && i < CFArrayGetCount(a); i++) {
            CFDictionaryRef c = CFArrayGetValueAtIndex(a, i);
            int k = IOReportStateGetCount(c); double tot = 0, act = 0, wsum = 0;
            double r[32] = {0};
            for (int q = 0; q < k && q < 32; q++) { r[q] = IOReportStateGetResidency(c, q); tot += r[q]; if (q > 0) { act += r[q]; wsum += q * r[q]; } }
            if (tot > 0) { ph_active = act / tot; ph_avg = act > 0 ? wsum / act : 0; }
            for (int q = 1; q < k && q < 32; q++) if (tot > 0 && r[q] / tot >= 0.01) { char b[24]; snprintf(b, sizeof b, "%sP%d:%.0f", states[0] ? " " : "", q, 100 * r[q] / tot); strncat(states, b, sizeof states - strlen(states) - 1); }
        }
        if (h) CFRelease(h);
        ct[1] = tcpu();

        // gpuext
        double bst_a = NAN, bst_avg = NAN, sw_a = NAN, sw_avg = NAN, cltm = NAN, pzr = NAN, dvdh = NAN, dvdh_act = NAN, ppm = NAN;
        char pwr_top[24] = ""; long long ut_sum = 0, ut_cnt = 0, tavs = -1, tavc = -1, tmax = -1;
        a = sub_delta(&sExt, &h);
        for (CFIndex i = 0; a && i < CFArrayGetCount(a); i++) {
            CFDictionaryRef c = CFArrayGetValueAtIndex(a, i);
            char nm[128], sg[128]; cs(IOReportChannelGetChannelName(c), nm, sizeof nm); cs(IOReportChannelGetSubGroup(c), sg, sizeof sg);
            int fmt = IOReportChannelGetFormat(c);
            if (fmt == 2) {
                int k = IOReportStateGetCount(c); double r[40] = {0}, tot = 0;
                for (int q = 0; q < k && q < 40; q++) { r[q] = IOReportStateGetResidency(c, q); tot += r[q]; }
                if (tot <= 0) continue;
                if (streq(nm, "BSTGPUPH") || streq(nm, "GPU_SW")) {
                    double act = 0, w = 0; for (int q = 1; q < k; q++) { act += r[q]; w += q * r[q]; }
                    if (streq(nm, "BSTGPUPH")) { bst_a = act / tot; bst_avg = act > 0 ? w / act : 0; } else { sw_a = act / tot; sw_avg = act > 0 ? w / act : 0; }
                } else if (streq(nm, "GPU_CLTM")) {
                    // 最后一个状态是 NO_CLTM；其余（含 OFF）视为受限或关断，单独看 P 档部分
                    double lim = 0; for (int q = 1; q < k - 1; q++) lim += r[q]; cltm = lim / tot;
                } else if (streq(nm, "PWRCTRL")) {
                    int best = -1; double bv = -1; for (int q = 0; q < k; q++) if (r[q] > bv) { bv = r[q]; best = q; }
                    char sn[16]; cs(IOReportStateGetNameForIndex(c, best), sn, sizeof sn); snprintf(pwr_top, sizeof pwr_top, "%s:%.0f", sn, 100 * bv / tot);
                } else if (streq(nm, "PZRSDNCY")) {
                    pzr = (tot - r[0]) / tot;
                } else if (streq(nm, "GPUDVDH") || streq(nm, "GPU_PPM")) {
                    double w = 0, wa = 0, ta = 0;
                    for (int q = 0; q < k; q++) { double mid = q == 10 ? 100 : q * 10 + 4.5; w += mid * r[q]; if (q > 0) { wa += mid * r[q]; ta += r[q]; } }
                    if (streq(nm, "GPUDVDH")) { dvdh = w / tot; dvdh_act = ta > 0 ? wa / ta : 0; } else ppm = w / tot;
                }
            } else if (fmt == 1) {
                long long v = IOReportSimpleGetIntegerValue(c, 0);
                if (streq(sg, "Sum")) ut_sum += v; else if (streq(sg, "Count")) ut_cnt += v;
                else if (streq(sg, "Temperature")) {
                    if (streq(nm, "Average Sum")) tavs = v; else if (streq(nm, "Average Sum Count")) tavc = v; else if (streq(nm, "Max")) tmax = v;
                }
            }
        }
        if (h) CFRelease(h);
        ct[2] = tcpu();

        // energy
        double gpu_w = NAN;
        a = sub_delta(&sEn, &h);
        if (a && CFArrayGetCount(a) == 1 && dt > 0) gpu_w = IOReportSimpleGetIntegerValue(CFArrayGetValueAtIndex(a, 0), 0) / 1e9 / dt;
        if (h) CFRelease(h);
        ct[3] = tcpu();

        // pmgr（取绝对值，检测变化）
        int nchg = 0; long long gpuMJ = -1, aneMJ = -1, aveMJ = -1;
        if (sPM.sub) {
            CFDictionaryRef cur = IOReportCreateSamples(sPM.sub, sPM.subbed, NULL);
            CFArrayRef ca = cur ? CFDictionaryGetValue(cur, CFSTR("IOReportChannels")) : NULL;
            char chg[2048] = "";
            for (CFIndex i = 0; ca && i < CFArrayGetCount(ca) && i < 64; i++) {
                CFDictionaryRef c = CFArrayGetValueAtIndex(ca, i);
                char nm[48]; cs(IOReportChannelGetChannelName(c), nm, sizeof nm);
                long long v = IOReportSimpleGetIntegerValue(c, 0);
                if (first) { strcpy(pmgrName[i], nm); pmgrPrev[i] = v; npmgr = (int)i + 1; }
                else if (pmgrPrev[i] != v) { nchg++; char b[96]; snprintf(b, sizeof b, " %s%+lld", nm, v - pmgrPrev[i]); strncat(chg, b, sizeof chg - strlen(chg) - 1); pmgrPrev[i] = v; }
                if (streq(nm, "GPU") || streq(nm, "GPU0")) gpuMJ = v;
                else if (streq(nm, "ANE") || streq(nm, "ANE0")) aneMJ = v;
                else if (streq(nm, "AVE") || streq(nm, "AVE0")) aveMJ = v;
            }
            if (first || nchg) {
                fprintf(fp, "=== %.3f %s nchanged=%d%s\n", t, first ? "START" : "CHANGE", nchg, chg);
                for (int i = 0; i < npmgr; i++) fprintf(fp, "%s|%lld\n", pmgrName[i], pmgrPrev[i]);
                fflush(fp);
            }
            if (cur) CFRelease(cur);
        }
        ct[4] = tcpu();

        // irq
        double irq[6] = {0, 0, 0, 0, 0, 0}; int irqSeen[6] = {0};
        a = sub_delta(&sIRQ, &h);
        for (CFIndex i = 0; a && i < CFArrayGetCount(a); i++) {
            CFDictionaryRef c = CFArrayGetValueAtIndex(a, i);
            char sg[128]; cs(IOReportChannelGetSubGroup(c), sg, sizeof sg);
            double v = IOReportSimpleGetIntegerValue(c, 0) / (dt > 0 ? dt : 1);
            int idx = startswith(sg, "ave") ? 0 : startswith(sg, "avd") ? 1 : startswith(sg, "apr") ? 2 : startswith(sg, "jpeg") ? 3 : startswith(sg, "scaler") ? 4 : startswith(sg, "ane") ? 5 : -1;
            if (idx >= 0) { irq[idx] += v; irqSeen[idx] = 1; }
        }
        if (h) CFRelease(h);
        for (int q = 0; q < 6; q++) if (!irqSeen[q]) irq[q] = NAN;
        ct[5] = tcpu();

        // pmp：加权档位（档号 × 驻留 / 总驻留），相对量
        double pmp[6] = {NAN, NAN, NAN, NAN, NAN, NAN};
        a = sub_delta(&sPMP, &h);
        double acc[6] = {0}, tot6[6] = {0}; int seen6[6] = {0};
        for (CFIndex i = 0; a && i < CFArrayGetCount(a); i++) {
            CFDictionaryRef c = CFArrayGetValueAtIndex(a, i);
            char nm[128], sg[128]; cs(IOReportChannelGetChannelName(c), nm, sizeof nm); cs(IOReportChannelGetSubGroup(c), sg, sizeof sg);
            int idx;
            if (streq(sg, "AF BW")) idx = startswith(nm, "AGX") ? 0 : startswith(nm, "ANE") ? 1 : startswith(nm, "AVE") ? 2 : startswith(nm, "AVD") ? 3 : -1;
            else idx = strstr(nm, "ANE") ? 4 : strstr(nm, "AVE") ? 5 : -1;
            if (idx < 0) continue;
            int k = IOReportStateGetCount(c); seen6[idx] = 1;
            for (int q = 0; q < k; q++) { double r = IOReportStateGetResidency(c, q); acc[idx] += q * r; tot6[idx] += r; }
        }
        for (int q = 0; q < 6; q++) if (seen6[q]) pmp[q] = tot6[q] > 0 ? acc[q] / tot6[q] : 0;  // 通道在但没有事件记 0；通道缺失为 nan
        if (h) CFRelease(h);
        ct[6] = tcpu();

        // smc
        float tv[MAXT]; double tgmax = NAN, tamax = NAN; int tgn = 0, tan = 0;
        for (int i = 0; i < ntk; i++) {
            if (smc_readf(tkeys[i], &tv[i])) { tv[i] = NAN; continue; }
            char nm[5]; s4(tkeys[i], nm);
            // 粗过滤：只把 5–130 °C 之间的值计入最大值（占位值在分析阶段另行识别）
            if (tv[i] > 5 && tv[i] < 130) {
                if (nm[1] == 'g') { if (isnan(tgmax) || tv[i] > tgmax) tgmax = tv[i]; tgn++; }
                else { if (isnan(tamax) || tv[i] > tamax) tamax = tv[i]; tan++; }
            }
        }
        ct[7] = tcpu();
        fprintf(ft, "%.3f", t); for (int i = 0; i < ntk; i++) fprintf(ft, ",%.3f", tv[i]); fprintf(ft, "\n");

        // coal
        double cgb = NAN, cgw = NAN, cab = NAN, caw = NAN, topb = 0; uint64_t topcid = 0;
        if (cl && cu) {
            static coal_entry ents[MAXC];
            int got = cl(2, 0, ents, sizeof ents); int ne = got / (int)sizeof(coal_entry);
            double s8 = 0, s41 = 0, s38 = 0, s39 = 0;
            for (int i = 0; i < ne; i++) {
                if (ents[i].tasks == 0) continue;
                uint64_t u[64]; if (cu(ents[i].id, u, sizeof u)) continue;
                CoalPrev *p = cfind(ents[i].id); if (!p) continue;
                if (p->seen) {
                    double d8 = (double)(u[8] - p->s8);
                    if (u[8] >= p->s8) s8 += d8;
                    if (u[41] >= p->s41) s41 += (double)(u[41] - p->s41);
                    if (u[38] >= p->s38) s38 += (double)(u[38] - p->s38);
                    if (u[39] >= p->s39) s39 += (double)(u[39] - p->s39);
                    if (u[8] >= p->s8 && d8 > topb) { topb = d8; topcid = ents[i].id; }
                }
                p->s8 = u[8]; p->s41 = u[41]; p->s38 = u[38]; p->s39 = u[39]; p->seen = 1;
            }
            if (!first && dt > 0) { cgb = s8 / 1e9 / dt; cgw = s41 / 1e9 / dt; cab = s38 * 125.0 / 3 / 1e9 / dt; caw = s39 / 1e9 / dt; topb = topb / 1e9 / dt; }
        }
        ct[8] = tcpu();

        // ioreg
        long long aneps = -1, inuse = -1, alloc = -1, dutil = -1;
        if (ane) {
            CFTypeRef pm = IORegistryEntryCreateCFProperty(ane, CFSTR("IOPowerManagement"), kCFAllocatorDefault, 0);
            aneps = dict_int(pm, "CurrentPowerState"); if (pm) CFRelease(pm);
        }
        if (agx) {
            CFTypeRef ps = IORegistryEntryCreateCFProperty(agx, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
            inuse = dict_int(ps, "In use system memory"); alloc = dict_int(ps, "Alloc system memory"); dutil = dict_int(ps, "Device Utilization %");
            if (ps) CFRelease(ps);
        }
        ct[9] = tcpu();

        if (!first) {
            fprintf(fo, "%.3f,%.3f", t, dt);
            for (int q = 1; q <= 9; q++) fprintf(fo, ",%.3f", (ct[q] - ct[q - 1]) * 1e3);
            fprintf(fo, ",%.4f,%.2f,\"%s\",%.4f,%.2f,%.4f,%.2f,%.4f,%s,%.4f,%.2f,%.2f,%.2f", ph_active, ph_avg, states, bst_a, bst_avg, sw_a, sw_avg, cltm, pwr_top, pzr, dvdh, dvdh_act, ppm);
            fprintf(fo, ",%lld,%lld,%lld,%lld,%lld", ut_sum, ut_cnt, tavs, tavc, tmax);
            fprintf(fo, ",%.4f,%d,%lld,%lld,%lld", gpu_w, nchg, gpuMJ, aneMJ, aveMJ);
            for (int q = 0; q < 6; q++) fprintf(fo, ",%.2f", irq[q]);
            for (int q = 0; q < 6; q++) fprintf(fo, ",%.3f", pmp[q]);
            fprintf(fo, ",%.2f,%d,%.2f,%d", tgmax, tgn, tamax, tan);
            fprintf(fo, ",%.4f,%.4f,%.4f,%.4f,%llu,%.4f", cgb, cgw, cab, caw, (unsigned long long)topcid, topb);
            fprintf(fo, ",%lld,%.1f,%.1f,%lld\n", aneps, inuse / 1048576.0, alloc / 1048576.0, dutil);
            if (n % 10 == 0) fflush(fo);
            n++;
        }
        first = 0;
    }
    struct rusage_info_v6 ru; proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ru);
    fprintf(stderr, "gpu_watch done: %ld rows, own CPU %.3f s, energy %.3f J\n", n, (ru.ri_user_time + ru.ri_system_time) / 1e9, ru.ri_energy_nj / 1e9);
    fclose(fo); fclose(fp); fclose(ft);
    return 0;
}
