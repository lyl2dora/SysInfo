// qosburn.c - spin N threads at a given QoS for S seconds (self-terminating) to see which Tp* keys belong to which cluster.
// Usage: ./qosburn <threads> <seconds> <bg|ui>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double secs; static qos_class_t q;
static void *spin(void *a) { pthread_set_qos_class_self_np(q, 0); volatile double x = 1; time_t end = time(NULL) + (time_t)secs; while (time(NULL) < end) for (int i = 0; i < 1000000; i++) x = x * 1.0000001 + 1e-9; return NULL; }
int main(int argc, char **argv) {
    int n = atoi(argv[1]); secs = atof(argv[2]); q = strcmp(argv[3], "bg") ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_BACKGROUND;
    pthread_t t[64]; for (int i = 0; i < n; i++) pthread_create(&t[i], NULL, spin, NULL);
    for (int i = 0; i < n; i++) pthread_join(t[i], NULL);
    printf("done %d threads %s %.0fs\n", n, argv[3], secs); return 0;
}
