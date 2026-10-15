// burn.c - 会自行结束的短时 CPU 负载（D18：每次 ≤60 s）。
// 用法：burn <秒> [ui:N] [ui25:N] [bg:N] [def:N] [ut:N]
//   ui = QOS_CLASS_USER_INTERACTIVE 满载；ui25 = USER_INTERACTIVE 25% 占空比（10 ms 周期）；
//   bg = QOS_CLASS_BACKGROUND；def = QOS_CLASS_DEFAULT；ut = QOS_CLASS_UTILITY
// 秒数硬上限 60；另设 alarm(秒+2) 兜底（SIGALRM 默认动作即终止进程）。
// build: xcrun clang -O1 -o burn burn.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <time.h>
#include <stdatomic.h>

static atomic_int stop_flag;
typedef struct { qos_class_t qos; int duty; } arg_t;
static double sink;

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void *spin(void *p) {
  arg_t *a = p; pthread_set_qos_class_self_np(a->qos, 0);
  double x = 1.0;
  while (!atomic_load_explicit(&stop_flag, memory_order_relaxed)) {
    if (a->duty >= 100) { for (int i = 0; i < 100000; i++) x = x * 1.0000001 + 0.5; continue; }
    uint64_t t0 = now_ns(), on = 10000000ull * a->duty / 100;   // 10 ms 周期
    while (now_ns() - t0 < on) for (int i = 0; i < 1000; i++) x = x * 1.0000001 + 0.5;
    usleep((useconds_t)((10000000ull - on) / 1000));
  }
  sink += x; return NULL;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: burn <sec<=60> ui:N ui25:N bg:N def:N ut:N\n"); return 2; }
  int secs = atoi(argv[1]); if (secs < 1) secs = 1; if (secs > 60) secs = 60;
  alarm(secs + 2);
  pthread_t th[256]; arg_t args[256]; int n = 0;
  for (int i = 2; i < argc; i++) {
    char kind[16] = ""; int cnt = 0; if (sscanf(argv[i], "%15[^:]:%d", kind, &cnt) != 2) continue;
    qos_class_t q = QOS_CLASS_DEFAULT; int duty = 100;
    if (!strcmp(kind, "ui")) q = QOS_CLASS_USER_INTERACTIVE;
    else if (!strcmp(kind, "ui25")) { q = QOS_CLASS_USER_INTERACTIVE; duty = 25; }
    else if (!strcmp(kind, "bg")) q = QOS_CLASS_BACKGROUND;
    else if (!strcmp(kind, "ut")) q = QOS_CLASS_UTILITY;
    for (int k = 0; k < cnt && n < 256; k++, n++) { args[n].qos = q; args[n].duty = duty; pthread_create(&th[n], NULL, spin, &args[n]); }
  }
  printf("burn pid %d: %d threads for %d s\n", getpid(), n, secs); fflush(stdout);
  sleep(secs);
  atomic_store(&stop_flag, 1);
  for (int i = 0; i < n; i++) pthread_join(th[i], NULL);
  return 0;
}
