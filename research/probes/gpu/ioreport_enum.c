// Enumerate all IOReport channels: group | subgroup | channel | format | unit | driver
// build: xcrun clang -O1 -o ioreport_enum ioreport_enum.c -framework CoreFoundation -lIOReport
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdint.h>

CFDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef a);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef a);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef a);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef a);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef a);
int32_t IOReportChannelGetFormat(CFDictionaryRef a);
uint64_t IOReportChannelGetChannelID(CFDictionaryRef a);

static void cs(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

int main(void) {
    CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
    if (!all) { printf("IOReportCopyAllChannels returned NULL\n"); return 1; }
    CFArrayRef chans = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    CFIndex n = chans ? CFArrayGetCount(chans) : 0;
    printf("# total channels: %ld\n", (long)n);
    printf("# group | subgroup | channel | format(1=simple,2=state,3=hist,4=simplearray) | unit | driver\n");
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(chans, i);
        char g[256], sg[256], nm[256], u[64], d[256];
        cs(IOReportChannelGetGroup(ch), g, sizeof g);
        cs(IOReportChannelGetSubGroup(ch), sg, sizeof sg);
        cs(IOReportChannelGetChannelName(ch), nm, sizeof nm);
        cs(IOReportChannelGetUnitLabel(ch), u, sizeof u);
        cs(IOReportChannelGetDriverName(ch), d, sizeof d);
        printf("%s | %s | %s | %d | %s | %s\n", g, sg, nm, IOReportChannelGetFormat(ch), u, d);
    }
    CFRelease(all);
    return 0;
}
