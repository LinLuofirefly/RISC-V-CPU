# 双发射 CPU 验证结果

以下记录来自 2026-10-14 保存的仿真和 Vivado 最终实现输出。当前入口为 `timingopt15`、`DCACHE_INDEX_BITS=8`，即 256 行 DCache。

## CoreMark 功能与 CPI

`timingopt13` 的紧凑 tag 版本、`timingopt14` 和 `timingopt15` 在同一 180 MHz 理想时钟及相同镜像下，测量区间结果一致：

| 指标 | 数值 |
| --- | ---: |
| CoreMark 迭代次数 | 100 |
| CPU 周期 | 31,445,017 |
| 主通道退休 | 25,928,186 |
| 副通道退休 | 4,677,591 |
| 总退休 | 30,605,777 |
| CPI | 1.027421 |
| 最终 CRC | `0x988c` |

CPU 周期取自 `COREMARK_CPI` 的测量区间，不是包含启动和命令行交互的 `COREMARK100_STATS` 全程计数。原始输出见 [CoreMark 运行记录](results/timingopt15/coremark100.txt)。100 次运行用于正确性和相对性能比较，不作为满足正式运行时长的 CoreMark 发布分数。

## 定向回归

[7 项运行记录](results/timingopt15/regression.txt) 覆盖：

1. RV32M 与整数副通道配对；
2. load→RV32M 依赖；
3. load 配对交换与单发射回退；
4. 分支配对准入；
5. MEM2 load 双通道前递；
6. 紧凑 cache tag 的 MMIO/DRAM 边界别名与 load→branch 旁路；
7. partial store、refill 冲突和同 index tag 替换。

## 180 MHz 最终实现未收敛

器件 `xc7k325tffg900-2`，Vivado 2023.2，PLL 实际输出 179.985601 MHz（周期 5.556 ns）。

| 覆盖层 | WNS / ns | WHS / ns | 时序通过 | bitstream |
| --- | ---: | ---: | --- | --- |
| `timingopt14` | −0.849 | +0.038 | 否 | 未生成 |
| `timingopt15` | −1.371 | +0.013 | 否 | 未生成 |

最终摘要：[timingopt14](results/timingopt14/build_summary.txt)、[timingopt15](results/timingopt15/build_summary.txt)。两次完整实现均包含综合、布局、物理优化、布线和最终重布线。`timingopt15` 的地址提前计算在行为仿真中保持相同 CPI，但这次布局布线的 setup 时序比 `timingopt14` 更差；180 MHz 仍是优化目标。

`timingopt13` 的大规模寄存器数据阵列版本在综合期间因磁盘空间不足终止，没有最终时序结论。早期单发射或其他覆盖层的已收敛频率不用于上述版本。

## 固件编译检查（2026-11-03）

使用仓库自带默认 CoreMark port、GCC 13.2.0，按下列配置重新编译成功：

```bash
make -C software/rtthread_nano/coremark \
  BUILD_DIR=/tmp/riscv_coremark_build.F9h64L \
  TIMER_PERIOD_CYCLES=1800000 IROM_WORDS=8192 \
  COREMARK_ITERATIONS=100 COREMARK_ALLOW_SHORT_RUN=1 \
  RTTHREAD_OPT_FLAGS=-O1 COREMARK_OPT_FLAGS=-O3
```

生成 ELF、反汇编、MEM 和 COE。IROM 有效内容 31,108 字节，小于 32 KiB 容量；ELF 的 `text/data/bss` 为 34,772 / 44 / 11,864 字节（`text` 包含放入 DRAM 的只读数据）。该编译检查没有替换上述固定仿真镜像。

## 复现

在仓库根目录执行：

```bash
bash rtl_overlays/timingopt15/run_regression.sh 8
bash rtl_overlays/timingopt15/run_coremark100.sh 8 180000000
```

Vivado 完整构建命令见 [构建指南](../fpga/vivado/README.md)。仿真使用 `sim/*.mem`，FPGA 使用对应覆盖层的 `images/*.coe`；不要用 `coremark/build/fpga` 的另一份固件替代本次镜像。
