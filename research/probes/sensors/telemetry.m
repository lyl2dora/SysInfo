// telemetry.m - read AppleSmartBattery "PowerTelemetryData" (present on this battery-less Mac mini) via public IORegistry API, no privileges.
// Usage: ./telemetry N ms
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
int main(int argc, const char **argv) { @autoreleasepool {
    int N = argc > 1 ? atoi(argv[1]) : 5, ms = argc > 2 ? atoi(argv[2]) : 1000;
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!s) { printf("no AppleSmartBattery\n"); return 1; }
    NSDictionary *prev = nil; NSDate *tp = nil;
    for (int i = 0; i < N; i++) {
        NSDictionary *t = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("PowerTelemetryData"), kCFAllocatorDefault, 0));
        NSDate *now = [NSDate date];
        printf("%s", [[NSString stringWithFormat:@"%@ SystemPowerIn=%@ mW SystemVoltageIn=%@ mV SystemCurrentIn=%@ mA SystemLoad=%@ WallEnergyEstimate=%@ AdapterEfficiencyLoss=%@ AccumulatedSystemPowerIn=%@ SystemPowerInAccumulatorCount=%@",
               [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle],
               t[@"SystemPowerIn"], t[@"SystemVoltageIn"], t[@"SystemCurrentIn"], t[@"SystemLoad"], t[@"WallEnergyEstimate"], t[@"AdapterEfficiencyLoss"], t[@"AccumulatedSystemPowerIn"], t[@"SystemPowerInAccumulatorCount"]] UTF8String]);
        if (prev) {
            double dAcc = [t[@"AccumulatedSystemPowerIn"] doubleValue] - [prev[@"AccumulatedSystemPowerIn"] doubleValue];
            double dCnt = [t[@"SystemPowerInAccumulatorCount"] doubleValue] - [prev[@"SystemPowerInAccumulatorCount"] doubleValue];
            printf("  | dAcc/dCnt=%.0f mW over %.0f ticks in %.2fs", dCnt > 0 ? dAcc / dCnt : NAN, dCnt, [now timeIntervalSinceDate:tp]);
        }
        printf("\n"); fflush(stdout);
        prev = t; tp = now;
        if (i < N - 1) usleep(ms * 1000);
    }
    IOObjectRelease(s);
} return 0; }
