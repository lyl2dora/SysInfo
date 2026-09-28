// Review probe: independent CPU temperature source = IOHIDEventSystemClient temperature services (AppleARM PMU tdie sensors),
// NOT SMC. Idle snapshot, then 6 threads QOS_CLASS_USER_INTERACTIVE (Super) for 8s, cool 25s, then 18 threads (all cores) 8s.
// Prints per-sensor rise so we can see which HID sensors track which cluster. Read-only.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
typedef struct __IOHIDEventSystemClient* IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient* IOHIDServiceClientRef;
typedef struct __IOHIDEvent* IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
#define kIOHIDEventTypeTemperature 15
static atomic_int stop_flag=0; static qos_class_t gq;
static void* spin(void* a){ pthread_set_qos_class_self_np(gq,0); volatile double x=1; while(!atomic_load(&stop_flag)) x=x*1.0000001+0.5; return NULL; }
static CFArrayRef svcs; static int n; static char names[256][64];
static void snap(double* v){ for(int i=0;i<n;i++){ IOHIDServiceClientRef s=(IOHIDServiceClientRef)CFArrayGetValueAtIndex(svcs,i); IOHIDEventRef e=IOHIDServiceClientCopyEvent(s,kIOHIDEventTypeTemperature,0,0); v[i]= e? IOHIDEventGetFloatValue(e, kIOHIDEventTypeTemperature<<16) : -1; if(e) CFRelease(e);} }
static void phase(const char* name, qos_class_t q, int nth){
  static double b[256], a[256]; snap(b); gq=q; atomic_store(&stop_flag,0); pthread_t th[32]; for(int i=0;i<nth;i++) pthread_create(&th[i],NULL,spin,NULL);
  sleep(8); snap(a); atomic_store(&stop_flag,1); for(int i=0;i<nth;i++) pthread_join(th[i],NULL);
  printf("\n== %s ==\n", name);
  for(int i=0;i<n;i++) printf("  %-24s base=%6.2f after=%6.2f rise=%+6.2f\n", names[i], b[i], a[i], a[i]-b[i]);
}
int main(){
  IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  int page=0xff00, usage=5; CFNumberRef p=CFNumberCreate(0,kCFNumberIntType,&page), u=CFNumberCreate(0,kCFNumberIntType,&usage);
  const void* k[]={CFSTR("PrimaryUsagePage"),CFSTR("PrimaryUsage")}; const void* v[]={p,u};
  CFDictionaryRef m=CFDictionaryCreate(0,k,v,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  IOHIDEventSystemClientSetMatching(c,m); svcs=IOHIDEventSystemClientCopyServices(c);
  n = svcs? (int)CFArrayGetCount(svcs):0; if(n>256) n=256; printf("HID temperature services: %d\n", n);
  for(int i=0;i<n;i++){ CFTypeRef pr=IOHIDServiceClientCopyProperty((IOHIDServiceClientRef)CFArrayGetValueAtIndex(svcs,i),CFSTR("Product")); names[i][0]=0; if(pr && CFGetTypeID(pr)==CFStringGetTypeID()) CFStringGetCString(pr,names[i],64,kCFStringEncodingUTF8); if(pr) CFRelease(pr); }
  phase("6 threads USER_INTERACTIVE (Super cluster)", QOS_CLASS_USER_INTERACTIVE, 6);
  sleep(25);
  phase("18 threads USER_INITIATED (all cores)", QOS_CLASS_USER_INITIATED, 18);
  return 0;
}
