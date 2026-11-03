# Vivado 构建与下载

目标器件为 `xc7k325tffg900-2`，工具为 Windows Vivado 2023.2，板级顶层为 `top`。

## 当前双发射覆盖层：独立建工程

当前入口 `run_timingopt13.ps1` 支持 `timingopt13/14/15`，无需仓库外的 `.xpr`。它从仓库的 RTL、XCI、XDC 和匹配 COE 创建隔离工程。

在仓库根目录的 PowerShell 中执行：

```powershell
./fpga/vivado/run_timingopt13.ps1 `
  -CacheBits 8 `
  -BuildTag coremark_dual_180MHz_timingopt15_new `
  -Drive V: `
  -OverlayName timingopt15
```

- `BuildTag` 使用新名称；脚本拒绝覆盖已有工程。
- `Drive` 选择未占用的盘符，用于中文/长路径下的临时短路径映射。
- Vivado 安装路径当前为 `E:\Vivado\Vivado\2023.2`，其他安装位置需修改驱动脚本。
- `CacheBits=8` 表示 256 行 DCache。
- IROM 为 8,192 个 32 位字，DRAM 为 65,536 个 32 位字。
- 固件取自所选覆盖层的 `images/irom.coe` 与 `images/dram.coe`。

输出分别在 `vivado_projects/<BuildTag>/` 和 `vivado_runs/<BuildTag>/`。全流程包括 IP/OOC 综合、顶层综合、布局、物理优化、布线、布线后优化及最终重布线。

### 用最终摘要决定能否上板

查看 `vivado_runs/<BuildTag>/build_summary.txt`：

```text
wns_ns=...
whs_ns=...
timing_met=1
bitstream_emitted=1
```

只有 setup/hold 均通过时，这个覆盖层流程才生成 `.bit`。脚本进程正常退出只说明流程完成；上板还需 `timing_met=1` 和 `bitstream_emitted=1`。

最近完成的 `timingopt14/15` 180 MHz 构建均未收敛，结果见 [验证记录](../../docs/RESULTS.md)。

## 普通 BSP/CoreMark 固件构建

Linux/WSL 下，示例为 180 MHz CPU、100 Hz RT-Thread tick：

```bash
make -C software/rtthread_nano/coremark \
  BUILD_DIR=build/fpga TIMER_PERIOD_CYCLES=1800000 \
  IROM_WORDS=8192 COREMARK_ITERATIONS=10000 \
  RTTHREAD_OPT_FLAGS=-O1 COREMARK_OPT_FLAGS=-O3
```

若链接内容超过 32 KiB，应明确扩大 IROM 并同步调整 RTL/IP 地址宽度及深度，而不是截断镜像。固件说明见 [CoreMark README](../../software/rtthread_nano/coremark/README.md)。重新编译的软件是另一份镜像，不会自动替换覆盖层中的固定测试镜像。

## 已有 digital_twin 工程：兼容入口

`build_bitstream.ps1` / `build_bitstream.tcl` 保留给已有 `digital_twin.xpr` 的使用者。PowerShell 包装器按旧目录布局定位仓库外的工程；新克隆优先用上面的独立覆盖层流程。

也可直接调用 Tcl，明确指定工程和固件：

```powershell
& "E:\Vivado\Vivado\2023.2\bin\vivado.bat" `
  -mode batch -source ./fpga/vivado/build_bitstream.tcl -tclargs `
  -project C:/path/to/digital_twin.xpr `
  -firmware_dir ./software/rtthread_nano/coremark/build/fpga `
  -freq_mhz 180 -irom_words 8192 -name rtthread_coremark_180MHz
```

`-check_only` 仅检查输入和工程配置。构建会同步 PLL 请求频率、CPU 时钟和 UART 参数，并重建 BRAM 初始化内容。兼容入口默认在时序失败时返回错误码 8，但保留诊断 bitstream；不能直接用于正式上板。

## 下载已通过时序的 bitstream

连接并上电开发板、接好 JTAG 后：

```powershell
./fpga/vivado/program_bitstream.ps1 `
  -Bitstream ./vivado_runs/<BuildTag>/<BuildTag>.bit
```

串口为 115200 baud、8N1。固件提供 `help`、`coremark` 和 `distance` 命令。该命令写入 FPGA SRAM，断电后消失。

HC-SR04 的 TRIG 为 G17（J7-1），ECHO 为 G18（J7-2）。传感器外接 5 V 电源并共地；ECHO 需降至 3.3 V，Bank 17 VADJ1 设为 3.3 V。约束文件为 `fpga/xdc/hcsr04_j7_g17_g18.xdc`。
