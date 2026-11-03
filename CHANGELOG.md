# 更新记录

## 2026-11-03 — 双发射 CPU 更新与仓库整理

### CPU 与软件

- 加入整数副通道、双通道寄存器堆和前递选择，配合指令配对及依赖检查。
- 更新同步 IROM 取指、分支预测及 redirect/hold 控制。
- 收录 `timingopt13/14/15` 完整覆盖层、匹配镜像和复现脚本；最新实验为 `timingopt15`。
- 缓存改进包括紧凑 tag、统一写端口，以及提前计算的 load 探测地址。
- 更新 RT-Thread v3.1.5 启动跟踪与 CoreMark 外部 port 兼容层、50 MHz 硬件计时和输出支持。
- 收录双发射、RV32M、load/store、前递和缓存冲突相关 testbench。

### 验证

- CoreMark 100 次：31,445,017 周期，30,605,777 条退休指令，CPI 1.027421，最终 CRC `0x988c`。
- `timingopt15` 的 7 项定向回归通过。
- 2026-11-03 重新编译默认 CoreMark port：ELF 和两份 COE 生成成功，IROM 有效内容 31,108 字节，可容纳于 32 KiB IROM。
- 更新已完成的 180 MHz 实现结论：`timingopt14` WNS −0.849 ns；`timingopt15` WNS −1.371 ns，均未输出 bitstream。

### 仓库

- 补充中文首页、构建入口、验证结果和第三方修改说明。
- 从版本管理中移除输入法缓存、Vivado 日志/PID/旧报告、临时 worktree 链接、编辑器私有配置和仿真备份；本地文件保留。
- 保留已有提交历史、软件依赖、PGO 输入数据和有效的 RTL/测试/初始化镜像。
- 默认主线采用当前双发射版本，原有主线的实验提交保留在合并历史中。

## 既有里程碑

- `6fc207e`：时钟与浮点支持调整，本轮 CPU 更新的起点。
- `5b4d199`：RT-Thread Nano 切换到 v3.1.5。
- `1d2abad`：CoreMark CRC16 自定义指令和编译识别流程。
- `727f9e3`：HC-SR04 测距命令和 64 KiB IROM 固件实验。
- `74b533f`：零拍前递实验 RTL 与 PGO 固件。

不同里程碑的频率、镜像容量和性能结果对应各自版本；当前实验结果见 [docs/RESULTS.md](docs/RESULTS.md)。
