// ups_ps.m - public IOPowerSources: dump every power source description (UPS on this Mac mini) + providing source.
#import <Foundation/Foundation.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
int main(void) { @autoreleasepool {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    NSArray *list = CFBridgingRelease(IOPSCopyPowerSourcesList(info));
    printf("providing source: %s\n", [(__bridge NSString *)IOPSGetProvidingPowerSourceType(info) UTF8String]);
    for (id ps in list) {
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, (__bridge CFTypeRef)ps);
        printf("---\n%s\n", d.description.UTF8String);
    }
    CFRelease(info);
} return 0; }
