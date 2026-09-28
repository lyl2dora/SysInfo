#include <stdio.h>
#include <dlfcn.h>
int main(void){ void* p=dlsym(RTLD_DEFAULT,"os_lockdown_mode_enabled"); printf("dlsym(os_lockdown_mode_enabled)=%p\n",p); if(p){ _Bool (*f)(void)=p; printf("value=%d\n",f()); } return 0; }
