#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int IOReportChannelGetFormat(CFDictionaryRef);
static void cs(CFStringRef s,char*b,int n){ b[0]=0; if(s) CFStringGetCString(s,b,n,kCFStringEncodingUTF8); }
int main(void){
  CFDictionaryRef em=IOReportCopyChannelsInGroup(CFSTR("Energy Model"),NULL,0,0,0);
  CFArrayRef ec=CFDictionaryGetValue(em,CFSTR("IOReportChannels"));
  int fmt[8]={0};
  for(long i=0;i<CFArrayGetCount(ec);i++){ CFDictionaryRef it=CFArrayGetValueAtIndex(ec,i); int f=IOReportChannelGetFormat(it); if(f>=0&&f<8) fmt[f]++;
    char nm[128],u[32]; cs(IOReportChannelGetChannelName(it),nm,128); cs(IOReportChannelGetUnitLabel(it),u,32);
    if(i<25 || strstr(nm,"CPU")&&i<400) { static int k=0; if(k++<45) printf("  #%ld fmt=%d %s (%s)\n",i,f,nm,u);} }
  printf("formats: "); for(int i=0;i<8;i++) printf("%d:%d ",i,fmt[i]); printf("\n");
  // groups in all channels with 'nergy' or 'ower'
  CFDictionaryRef all=IOReportCopyAllChannels(0,0); CFArrayRef ac=CFDictionaryGetValue(all,CFSTR("IOReportChannels"));
  CFMutableSetRef gs=CFSetCreateMutable(NULL,0,&kCFTypeSetCallBacks);
  for(long i=0;i<CFArrayGetCount(ac);i++){ CFStringRef g=IOReportChannelGetGroup(CFArrayGetValueAtIndex(ac,i)); if(g) CFSetAddValue(gs,g);}
  long gn=CFSetGetCount(gs); const void* vals[512]; CFSetGetValues(gs,vals); printf("groups(%ld):",gn);
  for(long i=0;i<gn&&i<512;i++){char b[128];cs(vals[i],b,128);printf(" [%s]",b);} printf("\n");
  return 0;}
