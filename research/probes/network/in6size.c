#include <sys/types.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet6/in6_var.h>
#include <stdio.h>
int main(){printf("sizeof(in6_ifreq)=%zu SIOCGIFAFLAG_IN6=0x%lx\n",sizeof(struct in6_ifreq),(unsigned long)SIOCGIFAFLAG_IN6);}
