// Dump C strings from __TEXT,__cstring / __oslogstring / __const of an image loaded from the dyld shared cache.
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
static void dump(const struct mach_header_64 *mh, const char *seg, const char *sect, const char *img){
  unsigned long sz=0; uint8_t *p=getsectiondata(mh,seg,sect,&sz); if(!p) return;
  unsigned long i=0; while(i<sz){ unsigned long j=i; while(j<sz && p[j]) j++; if(j-i>=6){ printf("%s\t%s\t%.*s\n", img, sect, (int)(j-i), p+i);} i=j+1; }
}
int main(int argc,char**argv){
  for(int a=1;a<argc;a++){ void*h=dlopen(argv[a],RTLD_LAZY|RTLD_NOLOAD); if(!h) h=dlopen(argv[a],RTLD_LAZY); if(!h){fprintf(stderr,"dlopen fail %s: %s\n",argv[a],dlerror()); continue;} }
  uint32_t n=_dyld_image_count();
  for(uint32_t i=0;i<n;i++){ const char*name=_dyld_get_image_name(i); int want=0; for(int a=1;a<argc;a++){ const char*b=strrchr(argv[a],'/'); if(b && strstr(name,b+1)) want=1; } if(!want) continue;
    const struct mach_header_64*mh=(const struct mach_header_64*)_dyld_get_image_header(i); const char*short_=strrchr(name,'/')+1;
    dump(mh,"__TEXT","__cstring",short_); dump(mh,"__TEXT","__oslogstring",short_); dump(mh,"__TEXT","__const",short_); }
  return 0; }
