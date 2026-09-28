#include <stdio.h>
#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>
extern uint32_t kpc_get_counter_count(uint32_t classes);
extern uint32_t kpc_get_config_count(uint32_t classes);
extern int DisplayServicesGetBrightness(CGDirectDisplayID, float*);
extern void* NStatManagerCreate(void*, void*, void*);
int main(void){
  printf("kpc_get_counter_count(3)=%u config_count(3)=%u\n",kpc_get_counter_count(3),kpc_get_config_count(3));
  float b=-1; int r=DisplayServicesGetBrightness(CGMainDisplayID(),&b); printf("DisplayServicesGetBrightness r=%d b=%f\n",r,b);
  printf("NStatManagerCreate addr=%p (not called)\n",(void*)&NStatManagerCreate);
  return 0;}
