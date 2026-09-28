#include <stdio.h>
#include <os/lockdown_mode.h>
int main(void){ printf("os_lockdown_mode_enabled()=%d\n", os_lockdown_mode_enabled()); return 0; }
