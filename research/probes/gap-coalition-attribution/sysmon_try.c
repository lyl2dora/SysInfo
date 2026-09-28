// sysmon_try.c - can an unentitled uid-501 process use libsysmon / sysmond (pid 369, the top/Activity Monitor backend)?
// API recovered from `xcrun dyld_info -disassemble /usr/lib/libsysmon.dylib` (sysmond-135):
//   sysmon_request_create_with_error(uint64 type /*1 process,2 system,3 coalition*/, void(^)(sysmon_table_t, const char *err))
//   sysmon_request_add_attribute(req, uint32 attr); sysmon_request_execute(req); sysmon_table_get_count/get_row; sysmon_row_get_value(row, attr) -> xpc_object_t
// build: xcrun clang -O1 -fblocks -o sysmon_try sysmon_try.c
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <unistd.h>
typedef void *sm_t;
typedef sm_t (*create_err_fn)(uint64_t, void (^)(sm_t, const char *));
typedef sm_t (*create_fn)(uint64_t, void (^)(sm_t));
typedef void (*add_fn)(sm_t, uint32_t);
typedef void (*exec_fn)(sm_t);
typedef uint64_t (*count_fn)(sm_t);
typedef sm_t (*row_fn)(sm_t, uint64_t);
typedef xpc_object_t (*val_fn)(sm_t, uint32_t);
int main(void) {
    void *h = dlopen("/usr/lib/libsysmon.dylib", RTLD_NOW);
    printf("dlopen(/usr/lib/libsysmon.dylib) = %p %s\n", h, h ? "" : dlerror());
    if (!h) return 1;
    const char *syms[] = {"sysmon_request_create","sysmon_request_create_with_error","sysmon_request_add_attribute","sysmon_request_add_attributes","sysmon_request_set_flags","sysmon_request_set_interval","sysmon_request_execute","sysmon_request_cancel","sysmon_table_get_count","sysmon_table_get_row","sysmon_table_get_timestamp","sysmon_row_get_value","sysmon_row_apply","sysmon_release","SYSMON_XPC_SERVICE_NAME",NULL};
    for (int i = 0; syms[i]; i++) printf("  dlsym %-34s %p\n", syms[i], dlsym(h, syms[i]));
    const char **svc = dlsym(h, "SYSMON_XPC_SERVICE_NAME"); if (svc) printf("SYSMON_XPC_SERVICE_NAME = \"%s\"\n", *svc);
    create_err_fn create = dlsym(h, "sysmon_request_create_with_error");
    add_fn add = dlsym(h, "sysmon_request_add_attribute"); exec_fn ex = dlsym(h, "sysmon_request_execute");
    count_fn cnt = dlsym(h, "sysmon_table_get_count"); row_fn getrow = dlsym(h, "sysmon_table_get_row"); val_fn getval = dlsym(h, "sysmon_row_get_value");
    // bitarray sizes per type from __TEXT,__const @0x1c4ae3448: type1=10 bytes (80 attrs), type2=5 (40), type3=2 (16)
    static int nattr[4] = {0, 80, 40, 16};
    static const char *tname[4] = {"", "process", "system", "coalition"};
    for (uint64_t type = 1; type <= 3; type++) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block int got = 0;
        sm_t req = create(type, ^(sm_t table, const char *err) {
            uint64_t n = table ? cnt(table) : 0;
            printf("type %llu (%s): handler table=%p rows=%llu err=%s\n", type, tname[type], table, n, err ? err : "(null)");
            if (table && n) { sm_t r = getrow(table, 0); for (int a = 1; a < nattr[type]; a++) { xpc_object_t v = getval(r, a); if (v) { char *d = xpc_copy_description(v); printf("   attr %2d = %s\n", a, d); free(d); } } }
            if (!got) { got = 1; dispatch_semaphore_signal(sem); }
        });
        printf("type %llu: request=%p\n", type, req);
        for (int a = 1; a < nattr[type]; a++) add(req, a);
        ex(req);
        long to = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
        printf("type %llu: %s\n", type, to ? "TIMEOUT (no reply in 5 s)" : "handler returned");
    }
    return 0;
}
