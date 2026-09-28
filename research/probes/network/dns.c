// Probe: DNS server discovery without SystemConfiguration: res_ninit (libresolv) and private dns_configuration_copy (dnsinfo, in libSystem).
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <resolv.h>
#include <net/if.h>
#include <stdint.h>
#include <stdlib.h>
#pragma pack(push, 4)
// Minimal dnsinfo.h layout (private header, stable since 10.x): only fields we read.
typedef struct { char *domain; int32_t n_nameserver; struct sockaddr **nameserver; uint16_t port; int32_t n_search; char **search;
                 int32_t n_sortaddr; void **sortaddr; char *options; uint32_t timeout; uint32_t search_order; uint32_t if_index; uint32_t flags; uint32_t reach_flags; } dns_resolver_t;
typedef struct { int32_t n_resolver; dns_resolver_t **resolver; int32_t n_scoped_resolver; dns_resolver_t **scoped_resolver; uint64_t generation; } dns_config_t;
#pragma pack(pop)
static void pr(const char *tag, dns_resolver_t *r) {
    char ifn[16] = "-"; if (r->if_index) if_indextoname(r->if_index, ifn);
    printf("%s domain=%s if=%s n_ns=%d:", tag, r->domain ? r->domain : "(default)", ifn, r->n_nameserver);
    for (int i = 0; i < r->n_nameserver; i++) { char b[64] = ""; struct sockaddr *sa = r->nameserver[i];
        if (sa->sa_family == AF_INET) inet_ntop(AF_INET, &((struct sockaddr_in *)sa)->sin_addr, b, sizeof b);
        else if (sa->sa_family == AF_INET6) inet_ntop(AF_INET6, &((struct sockaddr_in6 *)sa)->sin6_addr, b, sizeof b);
        printf(" %s", b); }
    printf("\n");
}
int main(void) { setvbuf(stdout, NULL, _IONBF, 0);
    res_state rs = calloc(1, sizeof(struct __res_state));
    if (res_ninit(rs) == 0) {
        printf("res_ninit nscount=%d:", rs->nscount);
        for (int i = 0; i < rs->nscount; i++) { char b[64]; inet_ntop(AF_INET, &rs->nsaddr_list[i].sin_addr, b, sizeof b); printf(" %s", b); }
        printf("\n"); res_ndestroy(rs);
    } else printf("res_ninit failed\n");
    dns_config_t *(*copy)(void) = dlsym(RTLD_DEFAULT, "dns_configuration_copy");
    void (*freec)(dns_config_t *) = dlsym(RTLD_DEFAULT, "dns_configuration_free");
    printf("dns_configuration_copy=%p\n", copy);
    if (copy) { dns_config_t *c = copy(); if (c) {
        printf("n_resolver=%d n_scoped=%d generation=%llu\n", c->n_resolver, c->n_scoped_resolver, c->generation);
        for (int i = 0; i < c->n_resolver && i < 3; i++) pr("  resolver", c->resolver[i]);
        for (int i = 0; i < c->n_scoped_resolver; i++) pr("  scoped", c->scoped_resolver[i]);
        freec(c); } }
    return 0;
}
