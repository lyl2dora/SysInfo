#include <stdio.h>
#include <dlfcn.h>
int main(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW);
    printf("dlopen=%p err=%s\n", h, h ? "" : dlerror());
    const char *syms[] = {"NStatManagerCreate","NStatManagerDestroy","NStatManagerAddAllTCP","NStatManagerAddAllUDP","NStatManagerAddAllTCPWithFilter","NStatManagerAddAllUDPWithFilter",
        "NStatManagerQueryAllSources","NStatManagerQueryAllSourcesDescriptions","NStatManagerSetFlags","NStatSourceSetCountsBlock","NStatSourceSetDescriptionBlock","NStatSourceSetRemovedBlock",
        "NStatSourceQueryDescription","NStatSourceQueryCounts","NStatManagerSetInterfaceSourceFD","NStatManagerAddAllRoutes","NStatManagerAddAllQUIC","NStatManagerAddAllConnections",
        "kNStatSrcKeyPID","kNStatSrcKeyProcessName","kNStatSrcKeyRxBytes","kNStatSrcKeyTxBytes","kNStatSrcKeyInterface","kNStatSrcKeyEPID","kNStatSrcKeyUUID","kNStatSrcKeyProvider","kNStatSrcKeyRemote","kNStatSrcKeyLocal",
        "kNStatSrcKeyRxCellularBytes","kNStatSrcKeyRxWiFiBytes","kNStatSrcKeyRxWiredBytes","kNStatSrcKeyTCPState", NULL};
    for (int i = 0; syms[i]; i++) printf("%-40s %p\n", syms[i], h ? dlsym(h, syms[i]) : NULL);
    return 0;
}
