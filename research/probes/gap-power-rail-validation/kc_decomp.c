// kc_decomp.c - read-only: decompress the LZFSE payload of the (world-readable) IMG4 kernelcache into scratch for static analysis.
#include <stdio.h>
#include <stdlib.h>
#include <compression.h>
int main(int c,char**v){ FILE*f=fopen(v[1],"rb"); fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET); unsigned char*b=malloc(n); fread(b,1,n,f); fclose(f);
  long off=atol(v[3]); size_t cap=400UL<<20; unsigned char*o=malloc(cap);
  size_t r=compression_decode_buffer(o,cap,b+off,n-off,NULL,COMPRESSION_LZFSE); printf("decoded %zu bytes\n",r); FILE*g=fopen(v[2],"wb"); fwrite(o,1,r,g); fclose(g); return 0; }
