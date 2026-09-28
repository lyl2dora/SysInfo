// CSysPrivate：SysInfo 的私有 C 层（D05、D23）。
//
// 规则：
// - 所有私有符号（IOReport、SMC、私有 IOHID、coalition、私有 IOPS …）只能在这一份头文件里声明，并用弱链接；
// - 只有 SysCollectors 可以依赖它。这个 target 不做成 library product，但下游（app、CLI）仍能看到它的
//   module map，编译器拦不住；隔离靠 scripts/check-private-imports.sh 的构建期检查（见 M0 设计偏离记录）；
// - 上层按数据源封装成带 selfTest() 的协议，业务代码不直接接触这里的符号。
//
// M0 阶段：只有占位，不声明任何私有符号。私有调用从 CPU 模块开始建立（D15）。

#ifndef CSYSPRIVATE_H
#define CSYSPRIVATE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 私有 C 层的接口版本号。每次在本头文件中增删私有符号时递增，
/// 诊断页和 sysinfo-cli 可以据此确认链接到的是哪一版私有层。
uint32_t csp_layer_version(void);

#ifdef __cplusplus
}
#endif

#endif /* CSYSPRIVATE_H */
