// Link against SDK PrivateFrameworks stubs (tbd-only, no headers) and call a
// harmless read-only function from each to prove -F$(SDKROOT)/System/Library/PrivateFrameworks works.
#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int kpc_get_counter_count(uint32_t classes);
extern int kpc_get_config_count(uint32_t classes);
int main(void) {
    float b = -1; int r = DisplayServicesGetBrightness(CGMainDisplayID(), &b);
    printf("DisplayServicesGetBrightness(main=%u) r=%d brightness=%.3f\n", CGMainDisplayID(), r, b);
    printf("kpc_get_counter_count(FIXED|CONFIGURABLE)=%d kpc_get_config_count=%d\n", kpc_get_counter_count(3), kpc_get_config_count(3));
    return 0;
}
