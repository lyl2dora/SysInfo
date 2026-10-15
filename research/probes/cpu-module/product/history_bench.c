// 历史库写入/占用模拟（CPU 模块产品方案 · K33/K34/K39 的估算依据）
//
// 只用系统自带的 libsqlite3（D23）。模拟「每分钟一个聚合桶」的写入，统计：
//   - 每行的实际磁盘占用（checkpoint 后的主库大小 / 行数）；
//   - 每次提交（一个事务）的线程 CPU 时间，中位数与 p95；
//   - 模拟一天写入量：本进程的逻辑写（ri_logical_writes）与物理写（ri_diskio_byteswritten）；
//   - 典型读：某指标 24 h 分钟级、7 d 小时级、导出全表；按保留期删除一天。
// 不访问任何硬件数据源；数据库放在调用者给的临时路径下，结束后由调用者删除。
//
// 用法：history_bench <db 路径> <布局 A|B|C> <每分钟系统指标行数> <每分钟应用行数> <每几分钟提交一次> <模拟天数>
//   A：metric_minute PRIMARY KEY(metric, t)，avg/max 用 REAL
//   B：metric_minute PRIMARY KEY(t, metric)，avg/max 用 REAL（按时间追加，写入局部性最好）
//   C：metric_minute PRIMARY KEY(metric, t)，avg/max 用按指标缩放的 INTEGER（比例 ×1e4）
//
// 编译：xcrun clang -O2 -Wall history_bench.c -lsqlite3 -o history_bench

#include <sqlite3.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <math.h>

static void die(sqlite3 *db, const char *what) {
    fprintf(stderr, "error %s: %s\n", what, db ? sqlite3_errmsg(db) : "?");
    exit(1);
}

static void exec(sqlite3 *db, const char *sql) {
    char *err = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &err) != SQLITE_OK) {
        fprintf(stderr, "exec failed: %s\n  sql: %s\n", err, sql);
        exit(1);
    }
}

static uint64_t tcpu(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
static uint64_t wall(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static off_t fsize(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 ? st.st_size : 0;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

static uint64_t rng_state = 0x9E3779B97F4A7C15ull;
static double rnd(void) {  // xorshift64*，确定性
    rng_state ^= rng_state >> 12; rng_state ^= rng_state << 25; rng_state ^= rng_state >> 27;
    return (double)((rng_state * 2685821657736338717ull) >> 11) / (double)(1ull << 53);
}

static void rusage_now(uint64_t *logical, uint64_t *physical) {
    struct rusage_info_v6 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) { *logical = *physical = 0; return; }
    *logical = ri.ri_logical_writes;
    *physical = ri.ri_diskio_byteswritten;
}

int main(int argc, char **argv) {
    if (argc != 7) {
        fprintf(stderr, "usage: %s <db> <A|B|C> <metrics/min> <apps/min> <commit_every_min> <days>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    char layout = argv[2][0];
    int metrics = atoi(argv[3]);
    int apps = atoi(argv[4]);
    int every = atoi(argv[5]);
    int days = atoi(argv[6]);
    if (every < 1) every = 1;

    char wal[1024], shm[1024];
    snprintf(wal, sizeof wal, "%s-wal", path);
    snprintf(shm, sizeof shm, "%s-shm", path);
    unlink(path); unlink(wal); unlink(shm);

    sqlite3 *db = NULL;
    if (sqlite3_open(path, &db) != SQLITE_OK) die(db, "open");
    printf("sqlite_version=%s\n", sqlite3_libversion());
    printf("config layout=%c metrics_per_min=%d apps_per_min=%d commit_every_min=%d days=%d\n",
           layout, metrics, apps, every, days);

    exec(db, "PRAGMA auto_vacuum=INCREMENTAL;");
    exec(db, "PRAGMA journal_mode=WAL;");
    exec(db, "PRAGMA synchronous=NORMAL;");

    if (layout == 'A') {
        exec(db, "CREATE TABLE metric_minute(metric INTEGER NOT NULL, t INTEGER NOT NULL, avg REAL, max REAL, "
                 "n INTEGER NOT NULL, PRIMARY KEY(metric, t)) WITHOUT ROWID;");
    } else if (layout == 'B') {
        exec(db, "CREATE TABLE metric_minute(t INTEGER NOT NULL, metric INTEGER NOT NULL, avg REAL, max REAL, "
                 "n INTEGER NOT NULL, PRIMARY KEY(t, metric)) WITHOUT ROWID;");
    } else {
        exec(db, "CREATE TABLE metric_minute(metric INTEGER NOT NULL, t INTEGER NOT NULL, avg INTEGER, max INTEGER, "
                 "n INTEGER NOT NULL, PRIMARY KEY(metric, t)) WITHOUT ROWID;");
    }
    exec(db, "CREATE TABLE metric_hour(metric INTEGER NOT NULL, t INTEGER NOT NULL, avg REAL, max REAL, "
             "n INTEGER NOT NULL, PRIMARY KEY(metric, t)) WITHOUT ROWID;");
    exec(db, "CREATE TABLE app_minute(t INTEGER NOT NULL, app INTEGER NOT NULL, cpu_ns INTEGER, energy_nj INTEGER, "
             "PRIMARY KEY(t, app)) WITHOUT ROWID;");

    sqlite3_stmt *ins = NULL, *insApp = NULL, *rollup = NULL;
    const char *insSQL = layout == 'B'
        ? "INSERT INTO metric_minute(t, metric, avg, max, n) VALUES(?2, ?1, ?3, ?4, ?5)"
        : "INSERT INTO metric_minute(metric, t, avg, max, n) VALUES(?1, ?2, ?3, ?4, ?5)";
    if (sqlite3_prepare_v2(db, insSQL, -1, &ins, NULL) != SQLITE_OK) die(db, "prepare ins");
    if (sqlite3_prepare_v2(db, "INSERT INTO app_minute VALUES(?1, ?2, ?3, ?4)", -1, &insApp, NULL) != SQLITE_OK)
        die(db, "prepare app");
    // 小时汇总：按覆盖秒数加权平均，最大值取最大。C 布局的缩放整数在汇总时还原成比例。
    const char *rollSQL = layout == 'C'
        ? "INSERT INTO metric_hour SELECT metric, t/60, sum(avg*n)/1e4/sum(n), max(max)/1e4, sum(n) "
          "FROM metric_minute WHERE t >= ?1 AND t < ?2 GROUP BY metric"
        : "INSERT INTO metric_hour SELECT metric, t/60, sum(avg*n)/sum(n), max(max), sum(n) "
          "FROM metric_minute WHERE t >= ?1 AND t < ?2 GROUP BY metric";
    if (sqlite3_prepare_v2(db, rollSQL, -1, &rollup, NULL) != SQLITE_OK) die(db, "prepare rollup");

    const int64_t start = 1788220800 / 60;  // 2026-09-01 00:00 UTC，按 Unix 分钟
    const int64_t minutes = (int64_t)days * 1440;
    const int64_t flushes = (minutes + every - 1) / every;
    uint64_t *flushCPU = calloc((size_t)flushes, sizeof(uint64_t));
    uint64_t *rollCPU = calloc((size_t)(minutes / 60 + 1), sizeof(uint64_t));
    int64_t nflush = 0, nroll = 0;

    double *level = calloc((size_t)metrics, sizeof(double));
    for (int i = 0; i < metrics; i++) level[i] = rnd();

    uint64_t lw0, pw0;
    rusage_now(&lw0, &pw0);
    uint64_t loopWall0 = wall(), loopCPU0 = tcpu();

    uint64_t t0 = 0;
    for (int64_t m = 0; m < minutes; m++) {
        int64_t t = start + m;
        if (m % every == 0) {
            t0 = tcpu();
            exec(db, "BEGIN");
        }
        for (int i = 0; i < metrics; i++) {
            level[i] += (rnd() - 0.5) * 0.1;
            if (level[i] < 0) level[i] = 0;
            if (level[i] > 1) level[i] = 1;
            double avg = level[i], mx = fmin(1, avg + rnd() * 0.2);
            sqlite3_bind_int64(ins, 1, i + 1);
            sqlite3_bind_int64(ins, 2, t);
            if (layout == 'C') {
                sqlite3_bind_int64(ins, 3, llround(avg * 1e4));
                sqlite3_bind_int64(ins, 4, llround(mx * 1e4));
            } else {
                sqlite3_bind_double(ins, 3, avg);
                sqlite3_bind_double(ins, 4, mx);
            }
            sqlite3_bind_int64(ins, 5, 60);
            if (sqlite3_step(ins) != SQLITE_DONE) die(db, "step ins");
            sqlite3_reset(ins);
        }
        for (int a = 0; a < apps; a++) {
            // 每分钟前 N 个应用：应用编号在 1..300 之间轮换，CPU 时间 0.3–60 s，能耗 0.1–300 J
            sqlite3_bind_int64(insApp, 1, t);
            sqlite3_bind_int64(insApp, 2, 1 + ((a * 37 + m) % 300));
            sqlite3_bind_int64(insApp, 3, (int64_t)(3e8 + rnd() * 6e10));
            sqlite3_bind_int64(insApp, 4, (int64_t)(1e8 + rnd() * 3e11));
            int rc = sqlite3_step(insApp);
            if (rc != SQLITE_DONE && rc != SQLITE_CONSTRAINT) die(db, "step app");
            sqlite3_reset(insApp);
        }
        if ((m + 1) % every == 0 || m + 1 == minutes) {
            exec(db, "COMMIT");
            flushCPU[nflush++] = tcpu() - t0;
        }
        if ((m + 1) % 60 == 0) {
            uint64_t r0 = tcpu();
            exec(db, "BEGIN");
            sqlite3_bind_int64(rollup, 1, t + 1 - 60);
            sqlite3_bind_int64(rollup, 2, t + 1);
            if (sqlite3_step(rollup) != SQLITE_DONE) die(db, "rollup");
            sqlite3_reset(rollup);
            exec(db, "COMMIT");
            rollCPU[nroll++] = tcpu() - r0;
        }
    }
    uint64_t loopWall = wall() - loopWall0, loopCPU = tcpu() - loopCPU0;
    uint64_t lw1, pw1;
    rusage_now(&lw1, &pw1);

    qsort(flushCPU, (size_t)nflush, sizeof(uint64_t), cmp_u64);
    qsort(rollCPU, (size_t)nroll, sizeof(uint64_t), cmp_u64);
    printf("loop wall=%.2f s cpu=%.2f s\n", loopWall / 1e9, loopCPU / 1e9);
    printf("flush_cpu_us median=%.1f p95=%.1f max=%.1f (n=%lld, 每次含 %d 分钟 × (%d 系统行 + %d 应用行))\n",
           flushCPU[nflush / 2] / 1e3, flushCPU[(int64_t)(nflush * 0.95)] / 1e3, flushCPU[nflush - 1] / 1e3,
           (long long)nflush, every, metrics, apps);
    if (nroll > 0)
        printf("hour_rollup_cpu_us median=%.1f p95=%.1f\n", rollCPU[nroll / 2] / 1e3, rollCPU[(int64_t)(nroll * 0.95)] / 1e3);
    printf("writes_per_sim_day logical=%.2f MB physical=%.2f MB\n",
           (double)(lw1 - lw0) / days / 1e6, (double)(pw1 - pw0) / days / 1e6);

    exec(db, "PRAGMA wal_checkpoint(TRUNCATE);");
    off_t size = fsize(path);
    int64_t mrows = minutes * metrics, arows = minutes * apps, hrows = (minutes / 60) * metrics;
    printf("rows metric_minute=%lld app_minute=%lld metric_hour=%lld\n", (long long)mrows, (long long)arows, (long long)hrows);
    printf("db_size=%.2f MB  per_sim_day=%.3f MB  bytes_per_row(all tables)=%.1f\n",
           size / 1e6, size / 1e6 / days, (double)size / (double)(mrows + arows + hrows));

    // 典型读
    sqlite3_stmt *q = NULL;
    const char *q24 = layout == 'B'
        ? "SELECT t, avg, max FROM metric_minute WHERE metric = ?1 AND t >= ?2 AND t < ?3"
        : "SELECT t, avg, max FROM metric_minute WHERE metric = ?1 AND t >= ?2 AND t < ?3";
    int64_t end = start + minutes;
    for (int pass = 0; pass < 2; pass++) {  // 第二遍是热缓存
        uint64_t c0 = tcpu(), w0 = wall();
        if (sqlite3_prepare_v2(db, q24, -1, &q, NULL) != SQLITE_OK) die(db, "prep q24");
        sqlite3_bind_int64(q, 1, 1);
        sqlite3_bind_int64(q, 2, end - 1440);
        sqlite3_bind_int64(q, 3, end);
        int n = 0;
        while (sqlite3_step(q) == SQLITE_ROW) n++;
        sqlite3_finalize(q);
        printf("read_24h_minute_one_metric pass%d rows=%d cpu=%.2f ms wall=%.2f ms\n", pass, n, (tcpu() - c0) / 1e6, (wall() - w0) / 1e6);
    }
    {
        uint64_t c0 = tcpu();
        sqlite3_prepare_v2(db, "SELECT t, avg, max FROM metric_hour WHERE metric = ?1 AND t >= ?2", -1, &q, NULL);
        sqlite3_bind_int64(q, 1, 1);
        sqlite3_bind_int64(q, 2, (end - 7 * 1440) / 60);
        int n = 0;
        while (sqlite3_step(q) == SQLITE_ROW) n++;
        sqlite3_finalize(q);
        printf("read_7d_hour_one_metric rows=%d cpu=%.2f ms\n", n, (tcpu() - c0) / 1e6);
    }
    {
        uint64_t c0 = tcpu();
        sqlite3_prepare_v2(db, "SELECT * FROM metric_minute ORDER BY t", -1, &q, NULL);
        int64_t n = 0;
        while (sqlite3_step(q) == SQLITE_ROW) n++;
        sqlite3_finalize(q);
        printf("export_scan_all_minute_sorted_by_t rows=%lld cpu=%.1f ms\n", (long long)n, (tcpu() - c0) / 1e6);
    }
    {
        uint64_t c0 = tcpu();
        char sql[256];
        snprintf(sql, sizeof sql, "DELETE FROM metric_minute WHERE t < %lld; DELETE FROM app_minute WHERE t < %lld;",
                 (long long)(start + 1440), (long long)(start + 1440));
        exec(db, "BEGIN"); exec(db, sql); exec(db, "COMMIT");
        uint64_t c1 = tcpu();
        exec(db, "PRAGMA incremental_vacuum;");
        printf("retention_delete_one_day cpu=%.1f ms incremental_vacuum cpu=%.1f ms\n", (c1 - c0) / 1e6, (tcpu() - c1) / 1e6);
    }

    sqlite3_finalize(ins); sqlite3_finalize(insApp); sqlite3_finalize(rollup);
    sqlite3_close(db);
    return 0;
}
