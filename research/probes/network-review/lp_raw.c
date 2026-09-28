// Review probe: raw dump of the ioctl /sbin/ifconfig issues just before printing "link rate"/"uplink rate"
// (command word 0xc1006992 = _IOWR('i', 146, 256-byte struct), found by disassembly). Dumps non-zero 64-bit words.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
int main(void) {
    const char *names[] = {"en0", "en1", "en2", "vmenet1", "lo0"};
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    for (int i = 0; i < 5; i++) {
        uint8_t buf[256]; memset(buf, 0, sizeof buf); strlcpy((char *)buf, names[i], IFNAMSIZ);
        int rc = ioctl(s, 0xc1006992UL, buf);
        printf("%-8s rc=%d %s\n", names[i], rc, rc ? strerror(errno) : "");
        if (!rc) for (int o = 16; o < 256; o += 8) { uint64_t v; memcpy(&v, buf + o, 8); if (v) printf("   off %3d: %llu (0x%llx)\n", o, v, v); }
    }
    return 0;
}
