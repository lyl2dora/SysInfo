#ifndef ioreport_bridge_h
#define ioreport_bridge_h
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;

CFDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef a, CFStringRef b, uint64_t c, uint64_t d, uint64_t e);
int32_t IOReportChannelGetFormat(CFDictionaryRef a);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef a, int32_t b);
void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef null);
IOReportSubscriptionRef IOReportCreateSubscription(void* a, CFMutableDictionaryRef b, CFMutableDictionaryRef* c, uint64_t d, CFTypeRef e);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef a, CFMutableDictionaryRef b, CFTypeRef c);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef c);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef a);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef a);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef a);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef a);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef a);
int32_t IOReportStateGetCount(CFDictionaryRef a);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef a, int32_t b);
int64_t IOReportStateGetResidency(CFDictionaryRef a, int32_t b);
int32_t IOReportHistogramGetBucketCount(CFDictionaryRef a);
int64_t IOReportHistogramGetBucketHits(CFDictionaryRef a, int32_t b);
int64_t IOReportHistogramGetBucketSum(CFDictionaryRef a, int32_t b);

#endif
