// memstatus_probe.c - read-only memorystatus_control() commands as a normal user (private syscall, declared manually).
// Only GET commands are used: 1=GET_PRIORITY_LIST, 4=GET_PRESSURE_STATUS, 8=GET_MEMLIMIT_PROPERTIES (self), 3=GET_JETSAM_SNAPSHOT (size query).
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
typedef struct { int32_t pid; int32_t priority; uint64_t user_data; int32_t limit; uint32_t state; } prio_entry_t;
typedef struct { int32_t memlimit_active; uint32_t memlimit_active_attr; int32_t memlimit_inactive; uint32_t memlimit_inactive_attr; } memlimit_props_t;
int main(void){
  errno=0; int r=memorystatus_control(1,0,0,NULL,0); printf("GET_PRIORITY_LIST size query -> %d errno=%d (%s)\n",r,r<0?errno:0,r<0?strerror(errno):"ok");
  if(r>0){ prio_entry_t*b=malloc(r); int r2=memorystatus_control(1,0,0,b,r); printf("  fetched %d bytes = %d entries; first: pid=%d prio=%d limit=%dMB\n",r2,(int)(r2/sizeof(prio_entry_t)),b[0].pid,b[0].priority,b[0].limit); }
  prio_entry_t one; errno=0; r=memorystatus_control(1,getpid(),0,&one,sizeof one); printf("GET_PRIORITY_LIST(self pid) -> %d errno=%d prio=%d limit=%d\n",r,r<0?errno:0,r>0?one.priority:-1,r>0?one.limit:-1);
  errno=0; r=memorystatus_control(4,0,0,NULL,0); printf("GET_PRESSURE_STATUS -> %d errno=%d (%s)\n",r,r<0?errno:0,r<0?strerror(errno):"ok");
  memlimit_props_t m; memset(&m,0,sizeof m); errno=0; r=memorystatus_control(8,getpid(),0,&m,sizeof m); printf("GET_MEMLIMIT_PROPERTIES(self) -> %d errno=%d active=%d inactive=%d\n",r,r<0?errno:0,m.memlimit_active,m.memlimit_inactive);
  errno=0; r=memorystatus_control(3,0,0,NULL,0); printf("GET_JETSAM_SNAPSHOT size query -> %d errno=%d (%s)\n",r,r<0?errno:0,r<0?strerror(errno):"ok");
  return 0;
}
