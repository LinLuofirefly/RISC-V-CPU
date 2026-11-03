# RISC-V FPGA CPU

面向 Xilinx Kintex-7 的 RV32IM 流水线 CPU 项目，包含双发射执行、分支预测、数据缓存，以及 RT-Thread Nano、CoreMark 和 HC-SR04 外设集成。

## 当前版本

- **CPU**：RV32IM、机器态 CSR/定时器中断；主执行通道加整数副通道，支持符合条件的双指令配对。
- **前端与访存**：BTB/RAS/间接跳转预测、双通道前递、load/store 配对和缓存命中旁路。
- **软件**：RT-Thread Nano v3.1.5、UART 命令行、CoreMark 1.0，以及可选的 `cmcrc16` 自定义指令。
- **目标器件**：`xc7k325tffg900-2`，Vivado 2023.2。

最新实验入口是 [`rtl_overlays/timingopt15`](rtl_overlays/timingopt15)，它覆盖 `imports/new` 和 `new` 中的同名文件。只编译基础目录不会得到最新版本。

### 验证进展

`timingopt15`、256 行 DCache、180 MHz 理想时钟下，CoreMark 100 次行为仿真：

| 指标 | 结果 |
| --- | ---: |
| 测量区间 CPU 周期 | 31,445,017 |
| 退休指令 | 30,605,777 |
| CPI | 1.027421 |
| 最终 CRC | `0x988c` |
| 定向回归 | 7 项通过 |

180 MHz 布线后时序仍未收敛：`timingopt15` 的 WNS 为 **−1.371 ns**、WHS 为 **+0.013 ns**，未生成 bitstream。100 次仿真用于功能和 CPI 比较；上板频率以实现报告为准。完整结果及 `timingopt14` 对比见 [验证结果](docs/RESULTS.md)。

## 快速运行仿真

在仓库根目录使用 Linux/WSL、Verilator 5.x、GCC/G++ 和 GNU Make：

```bash
# 双发射、依赖、缓存边界和 refill 冲突回归
bash rtl_overlays/timingopt15/run_regression.sh 8

# 256 行 DCache，180 MHz 理想时钟，CoreMark 100 次
bash rtl_overlays/timingopt15/run_coremark100.sh 8 180000000
```

`8` 为 cache index 位数，即 `2^8 = 256` 行。编译目录位于 `/tmp`，运行结果写入 `sim_results/`；CoreMark 默认使用仓库中的 `sim/irom.mem` 与 `sim/dram.mem`。

FPGA 构建使用覆盖层随附的匹配 COE，IROM 为 8,192 × 32 bit（32 KiB），DRAM 为 65,536 × 32 bit（256 KiB）。构建和下载方法见 [Vivado 指南](fpga/vivado/README.md)。

## 目录导航

| 目录 | 内容 |
| --- | --- |
| [`imports/new`](imports/new) | CPU 基础 RTL、预测器、寄存器堆与执行单元 |
| [`new`](new) | 板级顶层、存储模型、UART/外设桥与 testbench |
| [`rtl_overlays`](rtl_overlays) | `timingopt13/14/15` 可复现实验源码和镜像 |
| [`ip`](ip) | Vivado PLL、IROM、DRAM IP 配置 |
| [`fpga`](fpga) | 综合、布局布线、下载脚本与管脚约束 |
| [`sim`](sim) | 当前仿真镜像和汇编转换工具 |
| [`software/rtthread_nano`](software/rtthread_nano) | BSP、CoreMark、镜像工具和第三方源码 |
| [`imports/test_src`](imports/test_src) | 历史 src0/src1/src2 测试程序及转换工具 |
| [`docs`](docs) | 更新摘要及精选验证记录 |

## 软件和外设

- [RT-Thread Nano BSP](software/rtthread_nano/step8/README.md)
- [CoreMark 固件与 `cmcrc16`](software/rtthread_nano/coremark/README.md)
- UART 控制台：115200 baud、8N1；支持 `help`、`coremark` 和 `distance` 命令。
- HC-SR04：TRIG 接 G17，ECHO 接 G18；ECHO 需先转换为 3.3 V 电平。

## 提交与分支

本轮按 **CPU/固件更新、仓库清理、项目文档** 分组提交，摘要见 [CHANGELOG](CHANGELOG.md)。已发布历史保留，旧单指令和时序实验分支作为追溯入口；它们不代表当前 CPU 配置。

日志、Vivado 工程输出、波形、个人编辑器配置和无关项目不纳入版本管理。上游 CoreMark 与 RT-Thread 的来源、许可证分别保留在各自的 `third_party` 目录中。
