// appact_density.c - 应用活动模块：每分钟活跃应用的密度、各列 Top-K 的覆盖率、应用能耗合计对 SoC / 整机功率的覆盖（只读）。
// 用来定：每应用历史表存哪些列、每分钟存多少行（D30 现在只存「CPU 前 10」的 cpu_ns 与 energy_nj），以及「能耗」列的口径。
//
// 做法：
// - 每 W 秒全量扫描 resource coalition（规则同 AppSampler：新 cid 全量计入；id 不大于上次最大值、上次却不在的只建基线）；
// - 身份：成员中路径含 .app 的取最外层 .app 路径，否则取 pid 最小成员的可执行文件路径；pid 0 记 kernel_task。按 cid 缓存；
// - 每分钟按身份汇总各列：CPU(24–30)、CPU 能耗(11)、GPU 时间(8)、GPU 能耗(41)、ANE 能耗(39)、磁盘读写(6+7)、
//   中断/空闲唤醒(4/5)、pageins(49)、footprint(40，取分钟内最大)；
// - 每秒读一次 SMC 的 PZC0（SoC）与 PDTR（整机直流），按窗口平均，与该窗口的 Σ(11+41+39) 比较。
// build: xcrun clang -O2 -framework IOKit -framework CoreFoundation appact_density.c -o appact_density
// usage: appact_density <duration_s> [window_s=10]
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include "../cpu-module/processes/coal.h"

// ---- SMC（只读，selector 2 的 cmd 9/5） ----
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCParam;
static io_connect_t smc_conn;
static uint32_t k4(const char *s) { return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3]; }
static int smc_readf(const char *name, float *f) {
    SMCParam in = {0}, out = {0};
    size_t sz = sizeof out;
    in.key = k4(name);
    in.keyInfo.dataSize = 4;
    in.data8 = 5;
    if (IOConnectCallStructMethod(smc_conn, 2, &in, sizeof in, &out, &sz) != KERN_SUCCESS || out.result) return -1;
    memcpy(f, out.bytes, 4);
    return 0;
}

// ---- 列 ----
enum { C_CPU, C_CPUE, C_GPU, C_GPUE, C_ANEE, C_DISK, C_WAKE, C_PAGEIN, C_FOOT, NCOL };
static const char *colName[NCOL] = {"cpu", "cpuE", "gpu", "gpuE", "aneE", "disk", "wakeups", "pageins", "footprint"};

// ---- 身份表 ----
#define MAXID 4096
static char idKey[MAXID][256];
static int nid;
static int id_of(const char *key) {
    for (int i = 0; i < nid; i++) if (!strcmp(idKey[i], key)) return i;
    if (nid >= MAXID) return MAXID - 1;
    snprintf(idKey[nid], sizeof idKey[nid], "%s", key);
    return nid++;
}

#define MAXC 4096
static uint64_t cacheCid[MAXC];
static int cacheId[MAXC], ncache;

static int resolve(uint64_t cid, uint32_t tasks) {
    for (int i = 0; i < ncache; i++) if (cacheCid[i] == cid) return cacheId[i];
    size_t cap = (tasks + 16) * sizeof(pid_t);
    pid_t *pids = malloc(cap);
    size_t sz = cap;
    char key[256] = "";
    if (coal_pl(cid, pids, &sz) == 0) {
        int n = (int)(sz / sizeof(pid_t));
        pid_t lowest = -1;
        char best[256] = "";
        for (int i = 0; i < n; i++) {
            if (pids[i] == 0) { snprintf(key, sizeof key, "kernel_task"); break; }
            char path[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pids[i], path, sizeof path) <= 0) continue;
            char *app = strstr(path, ".app/");
            if (app) {
                app[4] = 0;
                if (!best[0] || strlen(path) < strlen(best)) snprintf(best, sizeof best, "%s", path);
            } else if (lowest < 0 || pids[i] < lowest) {
                lowest = pids[i];
                if (!best[0] || !strstr(best, ".app")) snprintf(best, sizeof best, "%s", path);
            }
        }
        if (!key[0]) snprintf(key, sizeof key, "%s", best[0] ? best : "?");
    }
    free(pids);
    if (!key[0] || !strcmp(key, "?")) snprintf(key, sizeof key, "cid:%llu", (unsigned long long)cid);
    int id = id_of(key);
    if (ncache < MAXC) { cacheCid[ncache] = cid; cacheId[ncache] = id; ncache++; }
    return id;
}

// ---- 扫描状态 ----
typedef struct { uint64_t cid; uint64_t s[COAL_BUF_SLOTS]; } Snap;
static Snap prevSnap[MAXC], curSnap[MAXC];
static int nprev, ncur;
static uint64_t prevMax;
static int havePrev;

static double minute[MAXID][NCOL];
static int seenEver[MAXID];

static int cmp_desc(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? 1 : x > y ? -1 : 0; }

typedef struct { double v; int id; } VI;
static int cmp_vi(const void *a, const void *b) { double x = ((const VI *)a)->v, y = ((const VI *)b)->v; return x < y ? 1 : x > y ? -1 : 0; }

static void topk(int col, int k, int *mark) {
    VI arr[MAXID];
    int n = 0;
    for (int i = 0; i < nid; i++) if (minute[i][col] > 0) arr[n++] = (VI){minute[i][col], i};
    qsort(arr, n, sizeof *arr, cmp_vi);
    for (int i = 0; i < n && i < k; i++) mark[arr[i].id] = 1;
}

// 每分钟统计
static double sumRows[3][4], sumActive[NCOL], sumCov[3][NCOL], sumCovCPU10[NCOL];
static int minutes;
static void flush_minute(int print) {
    int active[NCOL] = {0}, anyActive = 0;
    double total[NCOL] = {0};
    for (int i = 0; i < nid; i++) {
        int any = 0;
        for (int c = 0; c < NCOL; c++) {
            if (minute[i][c] > 0) { active[c]++; total[c] += minute[i][c]; if (c != C_FOOT) any = 1; }
        }
        if (any) { anyActive++; seenEver[i] = 1; }
    }
    static const int ks[3] = {5, 10, 20};
    int unionRows[3] = {0};
    double cov[3][NCOL];
    for (int k = 0; k < 3; k++) {
        int mark[MAXID] = {0};
        for (int c = 0; c < NCOL; c++) topk(c, ks[k], mark);
        for (int i = 0; i < nid; i++) unionRows[k] += mark[i];
        for (int c = 0; c < NCOL; c++) {
            double got = 0;
            for (int i = 0; i < nid; i++) if (mark[i]) got += minute[i][c];
            cov[k][c] = total[c] > 0 ? got / total[c] : 1;
            sumCov[k][c] += cov[k][c];
        }
    }
    // 现行方案：只存 CPU 前 10
    int markCPU[MAXID] = {0};
    topk(C_CPU, 10, markCPU);
    double covCPU10[NCOL];
    for (int c = 0; c < NCOL; c++) {
        double got = 0;
        for (int i = 0; i < nid; i++) if (markCPU[i]) got += minute[i][c];
        covCPU10[c] = total[c] > 0 ? got / total[c] : 1;
        sumCovCPU10[c] += covCPU10[c];
        sumActive[c] += active[c];
    }
    for (int k = 0; k < 3; k++) sumRows[k][0] += unionRows[k];
    sumRows[0][1] += anyActive;
    minutes++;
    if (print) {
        printf("minute %d: identities active(non-footprint) %d |", minutes, anyActive);
        for (int c = 0; c < NCOL; c++) printf(" %s %d", colName[c], active[c]);
        printf("\n   union rows top5/10/20 per column: %d / %d / %d\n", unionRows[0], unionRows[1], unionRows[2]);
        printf("   coverage of column total: by union-top10 |");
        for (int c = 0; c < NCOL; c++) printf(" %s %.3f", colName[c], cov[1][c]);
        printf("\n                             by CPU-top10   |");
        for (int c = 0; c < NCOL; c++) printf(" %s %.3f", colName[c], covCPU10[c]);
        printf("\n");
    }
    memset(minute, 0, sizeof minute);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: appact_density <duration_s> [window_s=10]\n"); return 1; }
    double dur = atof(argv[1]);
    int W = argc > 2 ? atoi(argv[2]) : 10;
    if (!coal_init()) { fprintf(stderr, "coalition symbols missing\n"); return 1; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    int smcOK = svc && IOServiceOpen(svc, mach_task_self(), 0, &smc_conn) == KERN_SUCCESS;
    double tb = tick_to_ns();

    uint64_t t0 = now_ns();
    double socSum = 0, dcSum = 0;
    int pn = 0;
    double ratioSoC[1024], ratioDC[1024], attribW[1024];
    int nr = 0;
    double scanCPU = 0;
    int scans = 0;
    int secInMinute = 0;
    for (int sec = 0; sec < (int)dur; sec++) {
        // 1 Hz：SMC 功率
        float soc, dc;
        if (smcOK && !smc_readf("PZC0", &soc) && !smc_readf("PDTR", &dc)) { socSum += soc; dcSum += dc; pn++; }
        if (sec % W == 0) {
            uint64_t c0 = thread_cpu_ns();
            struct coal_listent *ents;
            int n = coal_list(&ents);
            ncur = 0;
            uint64_t maxID = 0;
            for (int i = 0; i < n; i++) {
                if (ents[i].cid > maxID) maxID = ents[i].cid;
                if (ents[i].tasks == 0 || ncur >= MAXC) continue;
                memset(curSnap[ncur].s, 0, sizeof curSnap[ncur].s);
                if (coal_cru(ents[i].cid, curSnap[ncur].s, sizeof curSnap[ncur].s) != 0) continue;
                curSnap[ncur].cid = ents[i].cid;
                int id = resolve(ents[i].cid, ents[i].tasks);
                (void)id;
                ncur++;
            }
            double attrib = 0;
            if (havePrev) {
                for (int i = 0; i < ncur; i++) {
                    uint64_t *now = curSnap[i].s;
                    uint64_t *before = NULL;
                    for (int j = 0; j < nprev; j++) if (prevSnap[j].cid == curSnap[i].cid) { before = prevSnap[j].s; break; }
                    if (!before && curSnap[i].cid <= prevMax) continue;
                    static uint64_t zero[COAL_BUF_SLOTS];
                    if (!before) before = zero;
                    if (coal_cpu_ticks(now) < coal_cpu_ticks(before)) continue;
#define D(k) ((double)(now[k] >= before[k] ? now[k] - before[k] : 0))
                    int id = -1;
                    for (int c = 0; c < ncache; c++) if (cacheCid[c] == curSnap[i].cid) { id = cacheId[c]; break; }
                    if (id < 0) continue;
                    double *m = minute[id];
                    m[C_CPU] += (coal_cpu_ticks(now) - coal_cpu_ticks(before)) * tb;
                    m[C_CPUE] += D(11);
                    m[C_GPU] += D(8);
                    m[C_GPUE] += D(41);
                    m[C_ANEE] += D(39);
                    m[C_DISK] += D(6) + D(7);
                    m[C_WAKE] += D(4) + D(5);
                    m[C_PAGEIN] += D(49);
                    if (now[40] > m[C_FOOT]) m[C_FOOT] = now[40];
                    attrib += D(11) + D(41) + D(39);
#undef D
                }
                if (pn > 0 && nr < 1024) {
                    double w = attrib / 1e9 / W;
                    attribW[nr] = w;
                    ratioSoC[nr] = w / (socSum / pn);
                    ratioDC[nr] = w / (dcSum / pn);
                    printf("window %3d: attributed %.2f W | SoC PZC0 %.2f W -> %.3f | DC PDTR %.2f W -> %.3f\n", nr, w, socSum / pn,
                        ratioSoC[nr], dcSum / pn, ratioDC[nr]);
                    nr++;
                }
            }
            memcpy(prevSnap, curSnap, sizeof(Snap) * ncur);
            nprev = ncur;
            prevMax = maxID;
            havePrev = 1;
            free(ents);
            socSum = dcSum = 0;
            pn = 0;
            scanCPU += (thread_cpu_ns() - c0) / 1e6;
            scans++;
        }
        if (++secInMinute == 60) { flush_minute(1); secInMinute = 0; }
        uint64_t next = t0 + (uint64_t)(sec + 1) * 1000000000ull;
        uint64_t nowt = now_ns();
        if (next > nowt) usleep((useconds_t)((next - nowt) / 1000));
    }
    int seen = 0;
    for (int i = 0; i < nid; i++) seen += seenEver[i];
    printf("\n== summary over %d minutes ==\n", minutes);
    printf("identities ever resolved %d; ever active (non-footprint) %d; coalitions cached %d\n", nid, seen, ncache);
    printf("mean rows/minute: union top5 %.1f, top10 %.1f, top20 %.1f; all active %.1f\n", sumRows[0][0] / minutes,
        sumRows[1][0] / minutes, sumRows[2][0] / minutes, sumRows[0][1] / minutes);
    printf("mean active identities per column:");
    for (int c = 0; c < NCOL; c++) printf(" %s %.1f", colName[c], sumActive[c] / minutes);
    printf("\nmean coverage, union top5 :");
    for (int c = 0; c < NCOL; c++) printf(" %s %.3f", colName[c], sumCov[0][c] / minutes);
    printf("\nmean coverage, union top10:");
    for (int c = 0; c < NCOL; c++) printf(" %s %.3f", colName[c], sumCov[1][c] / minutes);
    printf("\nmean coverage, union top20:");
    for (int c = 0; c < NCOL; c++) printf(" %s %.3f", colName[c], sumCov[2][c] / minutes);
    printf("\nmean coverage, CPU top10  :");
    for (int c = 0; c < NCOL; c++) printf(" %s %.3f", colName[c], sumCovCPU10[c] / minutes);
    if (nr) {
        qsort(ratioSoC, nr, sizeof(double), cmp_desc);
        qsort(ratioDC, nr, sizeof(double), cmp_desc);
        qsort(attribW, nr, sizeof(double), cmp_desc);
        printf("\nattributed/SoC: median %.3f (min %.3f max %.3f); attributed/DC: median %.3f; attributed W median %.2f\n",
            ratioSoC[nr / 2], ratioSoC[nr - 1], ratioSoC[0], ratioDC[nr / 2], attribW[nr / 2]);
    }
    printf("scan+resolve thread CPU: %.2f ms/scan over %d scans\n", scanCPU / scans, scans);
    return 0;
}
