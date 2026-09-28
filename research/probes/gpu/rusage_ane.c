// Probe: proc_pid_rusage(RUSAGE_INFO_V6) for all pids -> ri_neural_footprint (ANE memory), ri_energy_nj
// usage: rusage_ane [pid-to-highlight]
// build: xcrun clang -O1 -o rusage_ane rusage_ane.c
#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>

int main(int argc, char **argv) {
    int hl = argc > 1 ? atoi(argv[1]) : -1;
    int pids[8192];
    int n = proc_listallpids(pids, sizeof pids) ;
    int ok = 0, eperm = 0, other = 0, withNeural = 0;
    for (int i = 0; i < n; i++) {
        struct rusage_info_v6 ri;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) { if (errno == EPERM) eperm++; else other++; continue; }
        ok++;
        char name[64] = {0}; proc_name(pids[i], name, sizeof name);
        if (ri.ri_neural_footprint > 0 || ri.ri_lifetime_max_neural_footprint > 0 || pids[i] == hl) {
            withNeural++;
            printf("pid %6d %-24s neural_footprint=%.2f MB lifetime_max_neural=%.2f MB energy=%.2f J phys_footprint=%.1f MB\n", pids[i], name,
                   ri.ri_neural_footprint / 1048576.0, ri.ri_lifetime_max_neural_footprint / 1048576.0, ri.ri_energy_nj / 1e9, ri.ri_phys_footprint / 1048576.0);
        }
    }
    printf("pids=%d readable=%d EPERM=%d other_err=%d with_neural>0=%d\n", n, ok, eperm, other, withNeural);
    return 0;
}
