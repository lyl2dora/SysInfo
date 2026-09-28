#include <stdio.h>
#include <dlfcn.h>
int main(void){ void*h=dlopen("/usr/lib/libSMC.dylib",RTLD_LAZY); printf("dlopen libSMC=%p err=%s\n",h,h?"":dlerror());
 const char* s[]={"SMCOpenConnection","SMCReadKey","SMCGetKeyInfo","SMCReadKeyAsNumeric","SMCGetKeyFromIndex"}; for(int i=0;i<5;i++) printf("  %s=%p\n",s[i],h?dlsym(h,s[i]):0); return 0; }
