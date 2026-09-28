// coalkit.h - C helpers for the coalmap probe (coalition_info_resource_usage slot mapping). Read-only APIs only.
#pragma once
#include <stdint.h>
#include <sys/resource.h>
#define CK_SLOTS 50
#define CK_MAXM 32
typedef struct { int pid; int ok; char name[32]; struct rusage_info_v6 ri; uint64_t agx_ns; } ck_member;
typedef struct { uint64_t t_ns; uint64_t cid; uint64_t s[64]; int nm; ck_member m[CK_MAXM]; double gpu_energy_j_since_prev; double gpu_active_s_since_prev; } ck_snap;
int ck_init(void);
uint64_t ck_self_cid(void);
void ck_snap_take(ck_snap *s, uint64_t cid);
void ck_print_delta(const char *phase, const ck_snap *a, const ck_snap *b);
void ck_log(const char *msg);
const char *ck_slot_name(int i);
