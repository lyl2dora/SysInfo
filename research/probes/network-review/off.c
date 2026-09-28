#include <stdio.h>
#include <stddef.h>
#include <net/if.h>
#include <net/route.h>
int main(void){printf("RTM_IFINFO2=%d ifm_index=%zu ifm_data=%zu ibytes=%zu obytes=%zu\n",RTM_IFINFO2,offsetof(struct if_msghdr2,ifm_index),offsetof(struct if_msghdr2,ifm_data),offsetof(struct if_msghdr2,ifm_data.ifi_ibytes),offsetof(struct if_msghdr2,ifm_data.ifi_obytes));}
