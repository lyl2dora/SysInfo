#include <stdio.h>
#include <unistd.h>
int sandbox_check(pid_t pid, const char *operation, int type, ...);
int main(void){ printf("sandbox_check(self, NULL) = %d (1 = sandboxed)\n", sandbox_check(getpid(), NULL, 0)); return 0; }
