// coal_list_check.c - proc_listcoalitions(LISTCOALITIONS_SINGLE_TYPE=2, COALITION_TYPE_RESOURCE=0) entry layout
// {u64 cid; u32 type; u32 task_count} vs coalition_info_pid_list count; empty (dead) coalitions still readable?
// build: xcrun clang -O1 -o coal_list_check coal_list_check.c
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
typedef int (*cru_fn)(uint64_t, void *, size_t); typedef int (*pl_fn)(uint64_t, void *, size_t *); typedef int (*lc_fn)(int, int, void *, int);
struct coalinfo { uint64_t cid; uint32_t type; uint32_t tasks; };
int main(void) { cru_fn cru = dlsym(RTLD_DEFAULT, "coalition_info_resource_usage"); pl_fn pl = dlsym(RTLD_DEFAULT, "coalition_info_pid_list"); lc_fn lc = dlsym(RTLD_DEFAULT, "proc_listcoalitions");
  int bytes = lc(2, 0, NULL, 0); struct coalinfo *ci = malloc(bytes + 8192); bytes = lc(2, 0, ci, bytes + 8192); int nc = bytes / sizeof *ci;
  int agree = 0, empty = 0, empty_readable = 0, typebad = 0; for (int i = 0; i < nc; i++) { int p[256]; size_t sz = sizeof p; pl(ci[i].cid, p, &sz); int n = sz / 4; if (n == (int)ci[i].tasks) agree++; if (ci[i].type != 0) typebad++;
    if (ci[i].tasks == 0) { empty++; uint64_t s[50]; if (cru(ci[i].cid, s, sizeof s) == 0) empty_readable++; } }
  int jb = lc(2, 1, NULL, 0);
  printf("resource coalitions listed=%d (bytes=%d, 16 B/entry); type field==0 for all: %s; tasks field == coalition_info_pid_list count: %d/%d; empty (0 live tasks) coalitions=%d, still readable via cru=%d; jetsam-type list bytes=%d (%d entries)\n",
    nc, bytes, typebad ? "no" : "yes", agree, nc, empty, empty_readable, jb, jb / 16);
  return 0; }
