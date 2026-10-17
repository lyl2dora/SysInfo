// appact_cost.c - 应用活动窗口「全表」刷新的真实节奏开销（只读）。
// 现有实测（cpu-module/processes/scan_cost.c）只覆盖 Top N：扫描全部 coalition + 解析前 10 行的名字。
// 应用活动窗口要显示全部 300–800 个 coalition，所以补测：
//   A 只扫描：proc_listcoalitions + 每个有成员的 coalition 读一次资源用量；
//   B 扫描 + 全部 coalition 冷解析：每个 coalition 取成员列表、对每个成员 proc_pidpath（首次打开窗口、无缓存）；
//   C 扫描 + 暖缓存：按 cid 缓存身份，只解析新出现的 coalition（窗口常开时的稳态）；
//   D 扫描 + 全部 coalition 取成员列表（不取路径）：表格要显示「成员数 / 成员变化」时每次都得做。
// 每种模式按 1 s、2 s、5 s 的真实节奏各跑若干 tick（醒来后的第一次调用），线程 QoS 为 utility，记线程 CPU。
// build: xcrun clang -O2 appact_cost.c -o appact_cost
#include <pthread/qos.h>
#include "../cpu-module/processes/coal.h"

#define MAXC 4096
static uint64_t cached[MAXC];
static int ncached;
static int is_cached(uint64_t cid) {
    for (int i = 0; i < ncached; i++) if (cached[i] == cid) return 1;
    return 0;
}

static int members(uint64_t cid, uint32_t tasks, pid_t *buf, size_t cap) {
    size_t sz = cap * sizeof(pid_t);
    if (tasks + 16 < cap) sz = (tasks + 16) * sizeof(pid_t);
    if (coal_pl(cid, buf, &sz) != 0) return 0;
    return (int)(sz / sizeof(pid_t));
}

static void tick(int mode, int *live, int *resolved) {
    static uint64_t slots[COAL_BUF_SLOTS];
    static pid_t pids[8192];
    struct coal_listent *ents;
    int n = coal_list(&ents);
    *live = 0;
    *resolved = 0;
    for (int i = 0; i < n; i++) {
        if (!ents[i].tasks) continue;
        if (coal_cru(ents[i].cid, slots, sizeof slots) != 0) continue;
        (*live)++;
        int doResolve = mode == 1 || (mode == 2 && !is_cached(ents[i].cid));
        if (doResolve || mode == 3) {
            int m = members(ents[i].cid, ents[i].tasks, pids, 8192);
            if (doResolve) {
                char path[PROC_PIDPATHINFO_MAXSIZE];
                for (int k = 0; k < m; k++) proc_pidpath(pids[k], path, sizeof path);
                (*resolved)++;
                if (mode == 2 && ncached < MAXC) cached[ncached++] = ents[i].cid;
            }
        }
    }
    free(ents);
}

int main(int argc, char **argv) {
    int ticks = argc > 1 ? atoi(argv[1]) : 8;
    if (!coal_init()) { fprintf(stderr, "coalition symbols missing\n"); return 1; }
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    static const char *names[4] = {"A scan only", "B scan + cold resolve all", "C scan + warm cache", "D scan + member lists"};
    static const int periods[3] = {1, 2, 5};
    for (int mode = 0; mode < 4; mode++) {
        for (int p = 0; p < 3; p++) {
            if (mode == 2) ncached = 0;
            double sum = 0, mx = 0;
            int live = 0, resolved = 0, resolvedSteady = 0;
            for (int t = 0; t <= ticks; t++) {
                sleep(periods[p]);
                uint64_t c0 = thread_cpu_ns();
                tick(mode, &live, &resolved);
                double ms = (thread_cpu_ns() - c0) / 1e6;
                if (t == 0) {
                    if (mode == 2) printf("   (C first tick, cache empty: %.2f ms, %d resolved)\n", ms, resolved);
                    continue;  // 第一次只建缓存 / 预热
                }
                sum += ms;
                if (ms > mx) mx = ms;
                resolvedSteady += resolved;
            }
            double mean = sum / ticks;
            printf("%-28s every %d s: %.2f ms/tick (max %.2f) = %.3f%% of one core | live coalitions %d, resolved/tick %.1f\n",
                names[mode], periods[p], mean, mx, mean / (periods[p] * 10.0), live, (double)resolvedSteady / ticks);
            fflush(stdout);
        }
    }
    return 0;
}
