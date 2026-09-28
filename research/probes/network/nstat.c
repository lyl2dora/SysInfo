// Probe: per-process traffic via private NetworkStatistics.framework (NStatManager), no entitlement, no root.
// Signatures reverse-engineered (same as used by open-source nettop clones); resolved with dlsym.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>

typedef void *NStatManagerRef;
typedef void *NStatSourceRef;
typedef NStatManagerRef (*CreateFn)(CFAllocatorRef, dispatch_queue_t, void (^)(NStatSourceRef, void *));
typedef void (*MgrFn)(NStatManagerRef);
typedef int (*MgrQueryFn)(NStatManagerRef, void (^)(void));
typedef void (*SrcBlockFn)(NStatSourceRef, void (^)(CFDictionaryRef));
typedef void (*SrcRemovedFn)(NStatSourceRef, void (^)(void));
typedef void (*SrcFn)(NStatSourceRef);

#define MAXS 8192
static struct { NStatSourceRef src; int pid; char name[64]; char ifname[16]; char prov[16]; unsigned long long rx, tx, rx_wifi, rx_wired; int have_desc; } S[MAXS];
static int nS = 0;
static CFStringRef kPID, kName, kRx, kTx, kIf, kProv, kRxWiFi, kRxWired;

static int find(NStatSourceRef s) { for (int i = 0; i < nS; i++) if (S[i].src == s) return i; return -1; }
static unsigned long long num(CFDictionaryRef d, CFStringRef k) {
    CFNumberRef n = k ? CFDictionaryGetValue(d, k) : NULL; long long v = 0;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberLongLongType, &v); return (unsigned long long)v;
}
static void str(CFDictionaryRef d, CFStringRef k, char *out, size_t n) {
    out[0] = 0; CFTypeRef v = k ? CFDictionaryGetValue(d, k) : NULL;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, out, n, kCFStringEncodingUTF8);
    else if (v && CFGetTypeID(v) == CFNumberGetTypeID()) { long long x; CFNumberGetValue(v, kCFNumberLongLongType, &x); snprintf(out, n, "%lld", x); }
}
static CFStringRef sym(void *h, const char *n) { CFStringRef *p = dlsym(h, n); return p ? *p : NULL; }

int main(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    CreateFn create = dlsym(h, "NStatManagerCreate");
    MgrFn addTCP = dlsym(h, "NStatManagerAddAllTCP"), addUDP = dlsym(h, "NStatManagerAddAllUDP"), destroy = dlsym(h, "NStatManagerDestroy");
    MgrQueryFn queryAll = dlsym(h, "NStatManagerQueryAllSources"), queryDesc = dlsym(h, "NStatManagerQueryAllSourcesDescriptions");
    SrcBlockFn setDesc = dlsym(h, "NStatSourceSetDescriptionBlock"), setCounts = dlsym(h, "NStatSourceSetCountsBlock");
    SrcRemovedFn setRemoved = dlsym(h, "NStatSourceSetRemovedBlock");
    kPID = sym(h, "kNStatSrcKeyPID"); kName = sym(h, "kNStatSrcKeyProcessName"); kRx = sym(h, "kNStatSrcKeyRxBytes"); kTx = sym(h, "kNStatSrcKeyTxBytes");
    kIf = sym(h, "kNStatSrcKeyInterface"); kProv = sym(h, "kNStatSrcKeyProvider"); kRxWiFi = sym(h, "kNStatSrcKeyRxWiFiBytes"); kRxWired = sym(h, "kNStatSrcKeyRxWiredBytes");

    dispatch_queue_t q = dispatch_queue_create("nstat", DISPATCH_QUEUE_SERIAL);
    __block int added = 0, removed = 0, descs = 0, counts = 0;
    NStatManagerRef m = create(kCFAllocatorDefault, q, ^(NStatSourceRef src, void *unused) {
        (void)unused;
        if (nS >= MAXS) return;
        int idx = nS++; S[idx].src = src; added++;
        setDesc(src, ^(CFDictionaryRef d) {
            int i = find(src); if (i < 0) return; descs++;
            S[i].pid = (int)num(d, kPID); str(d, kName, S[i].name, sizeof(S[i].name)); str(d, kIf, S[i].ifname, sizeof(S[i].ifname));
            str(d, kProv, S[i].prov, sizeof(S[i].prov)); S[i].have_desc = 1;
            S[i].rx = num(d, kRx); S[i].tx = num(d, kTx);
        });
        setCounts(src, ^(CFDictionaryRef d) {
            int i = find(src); if (i < 0) return; counts++;
            S[i].rx = num(d, kRx); S[i].tx = num(d, kTx); S[i].rx_wifi = num(d, kRxWiFi); S[i].rx_wired = num(d, kRxWired);
        });
        setRemoved(src, ^{ removed++; });
    });
    printf("NStatManagerCreate -> %p\n", m);
    if (!m) return 1;
    addTCP(m); addUDP(m);
    usleep(500000);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    int r1 = queryDesc(m, ^{ dispatch_semaphore_signal(sem); });
    long w1 = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC));
    int r2 = queryAll(m, ^{ dispatch_semaphore_signal(sem); });
    long w2 = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC));
    static unsigned long long first_rx[MAXS];
    dispatch_sync(q, ^{ for (int i = 0; i < nS; i++) first_rx[i] = S[i].rx + S[i].tx; });
    printf("after first query: rcDesc=%d waitDesc=%ld rcCounts=%d waitCounts=%ld sources=%d descs=%d counts=%d\n", r1, w1, r2, w2, added, descs, counts);
    sleep(2);
    queryAll(m, ^{ dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC));

    // aggregate per pid
    dispatch_sync(q, ^{
        static int pids[4096]; static char names[4096][64]; static unsigned long long rx[4096], tx[4096], d[4096]; int np = 0; int distinct_pids = 0;
        for (int i = 0; i < nS; i++) {
            int j; for (j = 0; j < np; j++) if (pids[j] == S[i].pid) break;
            if (j == np) { if (np >= 4096) continue; pids[np] = S[i].pid; strlcpy(names[np], S[i].name, 64); rx[np] = tx[np] = d[np] = 0; np++; distinct_pids++; }
            rx[j] += S[i].rx; tx[j] += S[i].tx; d[j] += (S[i].rx + S[i].tx) - first_rx[i];
        }
        printf("total sources=%d removed=%d distinct pids=%d  (own pid=%d)\n", nS, removed, distinct_pids, getpid());
        printf("%-7s %-28s %14s %14s %12s\n", "pid", "name", "rx_bytes", "tx_bytes", "delta_2s");
        for (int j = 0; j < np; j++) if (rx[j] + tx[j] > 0) printf("%-7d %-28s %14llu %14llu %12llu\n", pids[j], names[j], rx[j], tx[j], d[j]);
        int shown = 0;
        for (int i = 0; i < nS && shown < 5; i++) if (S[i].have_desc) { printf("sample source: pid=%d name=%s if=%s provider=%s rx=%llu tx=%llu rxWiFi=%llu rxWired=%llu\n", S[i].pid, S[i].name, S[i].ifname, S[i].prov, S[i].rx, S[i].tx, S[i].rx_wifi, S[i].rx_wired); shown++; }
    });
    destroy(m);
    return 0;
}
