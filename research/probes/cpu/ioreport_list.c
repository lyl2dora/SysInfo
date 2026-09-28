// Probe: enumerate all IOReport channels (group / subgroup / channel / unit / format / driver)
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
CFStringRef IOReportChannelGetDriverName(CFDictionaryRef);
int IOReportChannelGetFormat(CFDictionaryRef);
static void pr(CFStringRef s){ char b[512]="" ; if(s) CFStringGetCString(s,b,sizeof b,kCFStringEncodingUTF8); printf("%s",b); }
int main(void){
  CFDictionaryRef all = IOReportCopyAllChannels(0,0);
  if(!all){ printf("IOReportCopyAllChannels returned NULL\n"); return 1; }
  CFArrayRef arr = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
  CFIndex n = arr ? CFArrayGetCount(arr) : 0;
  printf("total channels: %ld\n", (long)n);
  for(CFIndex i=0;i<n;i++){
    CFDictionaryRef ch = CFArrayGetValueAtIndex(arr,i);
    pr(IOReportChannelGetGroup(ch)); printf(" | "); pr(IOReportChannelGetSubGroup(ch)); printf(" | ");
    pr(IOReportChannelGetChannelName(ch)); printf(" | unit="); pr(IOReportChannelGetUnitLabel(ch));
    printf(" | fmt=%d | drv=", IOReportChannelGetFormat(ch)); pr(IOReportChannelGetDriverName(ch)); printf("\n");
  }
  CFRelease(all);
  return 0;
}
