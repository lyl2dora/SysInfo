// 私有 IOReport 符号声明（与 research/probes/cpu/bridge_ioreport.h 相同的签名），探针共用。
#pragma once
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
uint64_t IOReportChannelGetChannelID(CFDictionaryRef);
uint64_t IOReportChannelGetDriverID(CFDictionaryRef);
int32_t IOReportChannelGetFormat(CFDictionaryRef);
int32_t IOReportStateGetCount(CFDictionaryRef);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
