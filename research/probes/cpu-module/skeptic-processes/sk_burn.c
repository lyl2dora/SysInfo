// sk_burn.c - 已知负载：N 个自旋线程跑 T 秒（T ≤ 60）。churn_ms > 0 时每个线程跑 churn_ms 后退出并由新线程接替（线程频繁生灭）。
// 用法：sk_burn N T [churn_ms=0]    build: xcrun clang -O1 -o sk_burn sk_burn.c
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
static double T; static int churn; static uint64_t t0;
static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void *spin(void *a) { (void)a; uint64_t s = now(); volatile double x = 1;
  while (now() - t0 < T * 1e9 && (!churn || now() - s < (uint64_t)churn * 1000000)) x = x * 1.0000001 + 0.5; return 0; }
static void *lane(void *a) { while (now() - t0 < T * 1e9) { pthread_t t; pthread_create(&t, 0, spin, a); pthread_join(t, 0); if (!churn) break; } return 0; }
int main(int argc, char **argv) { int n = argc > 1 ? atoi(argv[1]) : 2; T = argc > 2 ? atof(argv[2]) : 10; churn = argc > 3 ? atoi(argv[3]) : 0; if (T > 60) T = 60;
  printf("sk_burn pid %d: %d lanes x %.0f s, churn %d ms\n", getpid(), n, T, churn); fflush(stdout); t0 = now();
  pthread_t *l = calloc(n, sizeof *l); for (int i = 0; i < n; i++) pthread_create(&l[i], 0, lane, 0); for (int i = 0; i < n; i++) pthread_join(l[i], 0); return 0; }
