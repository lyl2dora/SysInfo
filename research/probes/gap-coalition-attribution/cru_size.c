// cru_size.c - (1) what buffer size does the kernel accept/return for COALITION_INFO_RESOURCE_USAGE on macOS 27,
// and does it write the size back?  Also tries the other read-only coalition_info flavors (debug_info=4, pid_list=5)
// and proc_listcoalitions (PROC_INFO_CALL_LISTCOALITIONS=0xb).  Read-only.
// build: xcrun clang -O1 -o cru_size cru_size.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>
struct pidcoal { uint64_t coalition_id[2]; uint64_t r1, r2, r3; };
typedef int (*cru_fn)(uint64_t, void *, size_t);
typedef int (*craw_fn)(uint32_t flavor, uint64_t *cid, void *buf, size_t *sz);
typedef int (*lc_fn)(int, int, void *, int);
typedef int (*pl_fn)(uint64_t, void *, size_t *);
static int written_len(const unsigned char *b, size_t cap, unsigned char pat) { int last = -1; for (size_t i = 0; i < cap; i++) if (b[i] != pat) last = (int)i; return last + 1; }
int main(void) {
    void *k = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW);
    cru_fn cru = (cru_fn)dlsym(k, "coalition_info_resource_usage");
    craw_fn raw = (craw_fn)dlsym(k, "__coalition_info");
    lc_fn lc = (lc_fn)dlsym(k, "proc_listcoalitions");
    pl_fn pl = (pl_fn)dlsym(k, "coalition_info_pid_list");
    void *dbg = dlsym(k, "coalition_info_debug_info");
    printf("dlsym(libsystem_kernel): coalition_info_resource_usage=%p __coalition_info=%p proc_listcoalitions=%p coalition_info_pid_list=%p coalition_info_debug_info=%p\n", cru, raw, lc, pl, dbg);
    struct pidcoal pc = {0}; proc_pidinfo(getpid(), 20, 0, &pc, sizeof pc);
    uint64_t cid = pc.coalition_id[0];
    printf("own pid %d: resource coalition %llu, jetsam coalition %llu\n", getpid(), pc.coalition_id[0], pc.coalition_id[1]);
    // sentinel test with two patterns, via raw syscall so we can see whether *sz is written back
    for (int pat = 0; pat < 2; pat++) {
        unsigned char p = pat ? 0x5A : 0xA5; unsigned char buf[8192]; memset(buf, p, sizeof buf);
        size_t sz = sizeof buf; uint64_t c = cid; errno = 0; int r = raw(1, &c, buf, &sz); int e = errno;
        printf("raw __coalition_info(1=RESOURCE_USAGE, bufsize=8192) rc=%d errno=%d, size after call=%zu, bytes actually overwritten (pattern 0x%02X)=%d -> %d u64 slots\n", r, r ? e : 0, sz, p, written_len(buf, sizeof buf, p), written_len(buf, sizeof buf, p) / 8);
    }
    // small sizes
    size_t sizes[] = {0, 8, 16, 48, 64, 200, 384, 392, 400, 408, 416, 424, 432, 480, 512, 1024};
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        unsigned char buf[2048]; memset(buf, 0xA5, sizeof buf); size_t sz = sizes[i]; uint64_t c = cid; errno = 0;
        int r = raw(1, &c, buf, &sz); int e = errno;
        printf("  bufsize %4zu: rc=%d errno=%d size-after=%zu overwritten=%d bytes\n", sizes[i], r, r ? e : 0, sz, written_len(buf, sizeof buf, 0xA5));
    }
    // invalid coalition id
    { uint64_t b[64]; errno = 0; int r = cru(0xFFFFFFFFull, b, sizeof b); printf("invalid cid 0xFFFFFFFF: rc=%d errno=%d (%s)\n", r, errno, strerror(errno)); }
    // debug_info flavor 4
    { unsigned char buf[4096]; memset(buf, 0xA5, sizeof buf); size_t sz = sizeof buf; uint64_t c = cid; errno = 0; int r = raw(4, &c, buf, &sz); int e = errno;
      printf("__coalition_info(4=DEBUG_INFO) rc=%d errno=%d (%s) size-after=%zu overwritten=%d\n", r, r ? e : 0, r ? strerror(e) : "", sz, written_len(buf, sizeof buf, 0xA5));
      if (r == 0) { uint64_t *u = (uint64_t *)buf; for (int i = 0; i < written_len(buf, sizeof buf, 0xA5) / 8 + 1 && i < 16; i++) printf("    dbg u64[%d]=%llu\n", i, u[i]); } }
    // pid list flavor 5
    { pid_t buf[1024]; memset(buf, 0xA5, sizeof buf); size_t sz = sizeof buf; errno = 0; int r = pl(cid, buf, &sz); int e = errno;
      printf("coalition_info_pid_list(own cid) rc=%d errno=%d (%s) size-after=%zu\n", r, r ? e : 0, r ? strerror(e) : "", sz);
      if (r >= 0) { printf("    first ints:"); for (int i = 0; i < 12; i++) printf(" %d", buf[i]); printf("\n"); } }
    { uint64_t c1 = 1; pid_t buf[256]; memset(buf, 0xA5, sizeof buf); size_t sz = sizeof buf; errno = 0; int r = pl(c1, buf, &sz); int e = errno;
      printf("coalition_info_pid_list(cid 1 = kernel_task/launchd, root) rc=%d errno=%d (%s) size-after=%zu first=%d %d\n", r, r ? e : 0, r ? strerror(e) : "", sz, buf[0], buf[1]); }
    // proc_listcoalitions(flavor, coaltype, buf, size)
    for (int fl = 1; fl <= 2; fl++) {
        errno = 0; int need = lc(fl, 0, NULL, 0); int e = errno;
        unsigned char *buf = calloc(1, 1 << 20); errno = 0; int got = lc(fl, 0, buf, 1 << 20); int e2 = errno;
        printf("proc_listcoalitions(flavor=%d, type=0): size-query=%d errno=%d; fill=%d errno=%d (%s)\n", fl, need, e, got, e2, got <= 0 ? strerror(e2) : "");
        if (got > 0) { uint64_t *u = (uint64_t *)buf; printf("    first 8 u64:"); for (int i = 0; i < 8; i++) printf(" 0x%llx", u[i]); printf("\n"); }
        free(buf);
    }
    return 0;
}
