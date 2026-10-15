// IOReport 的薄封装（CPU 模块设计 §3）。符号在运行时从 /usr/lib/libIOReport.dylib 解析，
// 签名与 research/probes/cpu-module/skeptic-topo-freq/sk.h 相同（来自社区资料，经两台目标机实测）。

#include "CSysPrivate.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>

typedef CFTypeRef IOReportSubscriptionRef;

static struct {
    CFMutableDictionaryRef (*copyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
    void (*mergeChannels)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    IOReportSubscriptionRef (*createSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t,
                                                  CFTypeRef);
    CFDictionaryRef (*createSamples)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*createSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    CFStringRef (*channelGetGroup)(CFDictionaryRef);
    CFStringRef (*channelGetSubGroup)(CFDictionaryRef);
    CFStringRef (*channelGetChannelName)(CFDictionaryRef);
    CFStringRef (*channelGetDriverName)(CFDictionaryRef);
    CFStringRef (*channelGetUnitLabel)(CFDictionaryRef);
    uint64_t (*channelGetChannelID)(CFDictionaryRef);
    int32_t (*stateGetCount)(CFDictionaryRef);
    CFStringRef (*stateGetNameForIndex)(CFDictionaryRef, int32_t);
    int64_t (*stateGetResidency)(CFDictionaryRef, int32_t);
    int64_t (*simpleGetIntegerValue)(CFDictionaryRef, int32_t *);
    int required;
} ior;

static pthread_once_t ior_once = PTHREAD_ONCE_INIT;

static void ior_load(void) {
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!lib) return;
#define LOAD(field, name) ior.field = dlsym(lib, name)
    LOAD(copyChannelsInGroup, "IOReportCopyChannelsInGroup");
    LOAD(mergeChannels, "IOReportMergeChannels");
    LOAD(createSubscription, "IOReportCreateSubscription");
    LOAD(createSamples, "IOReportCreateSamples");
    LOAD(createSamplesDelta, "IOReportCreateSamplesDelta");
    LOAD(channelGetGroup, "IOReportChannelGetGroup");
    LOAD(channelGetSubGroup, "IOReportChannelGetSubGroup");
    LOAD(channelGetChannelName, "IOReportChannelGetChannelName");
    LOAD(channelGetDriverName, "IOReportChannelGetDriverName");
    LOAD(channelGetUnitLabel, "IOReportChannelGetUnitLabel");
    LOAD(channelGetChannelID, "IOReportChannelGetChannelID");
    LOAD(stateGetCount, "IOReportStateGetCount");
    LOAD(stateGetNameForIndex, "IOReportStateGetNameForIndex");
    LOAD(stateGetResidency, "IOReportStateGetResidency");
    LOAD(simpleGetIntegerValue, "IOReportSimpleGetIntegerValue");
#undef LOAD
    // driver name、unit label 是可选的（只用于诊断与将来的功耗模块），其余缺一不可。
    ior.required = ior.copyChannelsInGroup && ior.mergeChannels && ior.createSubscription && ior.createSamples &&
                   ior.createSamplesDelta && ior.channelGetGroup && ior.channelGetSubGroup &&
                   ior.channelGetChannelName && ior.channelGetChannelID && ior.stateGetCount &&
                   ior.stateGetNameForIndex && ior.stateGetResidency && ior.simpleGetIntegerValue;
}

static int ior_ready(void) {
    pthread_once(&ior_once, ior_load);
    return ior.required;
}

int csp_ior_available(void) {
    return ior_ready();
}

CFMutableDictionaryRef csp_ior_copy_channels_in_group(CFStringRef group, CFStringRef subgroup) {
    if (!ior_ready()) return NULL;
    return ior.copyChannelsInGroup(group, subgroup, 0, 0, 0);
}

void csp_ior_merge_channels(CFMutableDictionaryRef dest, CFDictionaryRef source) {
    if (!ior_ready() || !dest || !source) return;
    ior.mergeChannels(dest, source, NULL);
}

struct csp_ior_subscription {
    IOReportSubscriptionRef handle;
    CFMutableDictionaryRef channels;
};

csp_ior_subscription *csp_ior_subscription_create(CFMutableDictionaryRef channels) {
    if (!ior_ready() || !channels) return NULL;
    CFMutableDictionaryRef subscribed = NULL;
    IOReportSubscriptionRef handle = ior.createSubscription(NULL, channels, &subscribed, 0, NULL);
    if (!handle || !subscribed) {
        if (handle) CFRelease(handle);
        if (subscribed) CFRelease(subscribed);
        return NULL;
    }
    csp_ior_subscription *s = calloc(1, sizeof *s);
    if (!s) {
        CFRelease(handle);
        CFRelease(subscribed);
        return NULL;
    }
    s->handle = handle;
    s->channels = subscribed;
    return s;
}

void csp_ior_subscription_destroy(csp_ior_subscription *s) {
    if (!s) return;
    if (s->handle) CFRelease(s->handle);
    if (s->channels) CFRelease(s->channels);
    free(s);
}

long csp_ior_subscription_channel_count(const csp_ior_subscription *s) {
    CFArrayRef array = CFDictionaryGetValue(s->channels, CFSTR("IOReportChannels"));
    if (!array || CFGetTypeID(array) != CFArrayGetTypeID()) return 0;
    return (long)CFArrayGetCount(array);
}

CFDictionaryRef csp_ior_subscription_sample(csp_ior_subscription *s) {
    if (!ior_ready()) return NULL;
    return ior.createSamples(s->handle, s->channels, NULL);
}

CFDictionaryRef csp_ior_samples_delta(CFDictionaryRef earlier, CFDictionaryRef later) {
    if (!ior_ready()) return NULL;
    return ior.createSamplesDelta(earlier, later, NULL);
}

CFStringRef csp_ior_channel_group(CFDictionaryRef c) { return ior_ready() ? ior.channelGetGroup(c) : NULL; }
CFStringRef csp_ior_channel_subgroup(CFDictionaryRef c) { return ior_ready() ? ior.channelGetSubGroup(c) : NULL; }
CFStringRef csp_ior_channel_name(CFDictionaryRef c) { return ior_ready() ? ior.channelGetChannelName(c) : NULL; }

CFStringRef csp_ior_channel_driver_name(CFDictionaryRef c) {
    return ior_ready() && ior.channelGetDriverName ? ior.channelGetDriverName(c) : NULL;
}

CFStringRef csp_ior_channel_unit_label(CFDictionaryRef c) {
    return ior_ready() && ior.channelGetUnitLabel ? ior.channelGetUnitLabel(c) : NULL;
}

uint64_t csp_ior_channel_id(CFDictionaryRef c) { return ior_ready() ? ior.channelGetChannelID(c) : 0; }
int32_t csp_ior_state_count(CFDictionaryRef c) { return ior_ready() ? ior.stateGetCount(c) : 0; }

CFStringRef csp_ior_state_name(CFDictionaryRef c, int32_t i) {
    return ior_ready() ? ior.stateGetNameForIndex(c, i) : NULL;
}

int64_t csp_ior_state_residency(CFDictionaryRef c, int32_t i) {
    return ior_ready() ? ior.stateGetResidency(c, i) : 0;
}

int64_t csp_ior_simple_integer(CFDictionaryRef c) {
    return ior_ready() ? ior.simpleGetIntegerValue(c, NULL) : 0;
}
