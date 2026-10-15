// sk_ior.h — skeptic-thermal-power 自己的私有 libIOReport 最小声明（只读订阅/采样）。
#pragma once
#include <CoreFoundation/CoreFoundation.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
int32_t IOReportChannelGetFormat(CFDictionaryRef);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t*);
static inline void sk_cf(CFStringRef s, char *b, int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
static inline double sk_unit_to_J(const char*u){ return !strcmp(u,"mJ")?1e-3: !strcmp(u,"uJ")?1e-6: !strcmp(u,"nJ")?1e-9: 0; }
