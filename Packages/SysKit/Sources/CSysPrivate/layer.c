// 私有 C 层的版本号（CPU 模块设计 §3）。

#include "CSysPrivate.h"

uint32_t csp_layer_version(void) {
    return CSP_LAYER_VERSION;
}
