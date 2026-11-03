# 构建

create_project.tcl 和 build.tcl 已在独立的 ../test 副本中使用 Vivado 2025.2 完整运行成功，完成新建工程、BD 校验与输出生成、综合、实现、bitstream 和含 bit 的 XSA 导出。发布源码、BD、XDC 未作功能修改；只更新了建工程脚本的首行状态注释。本次未重建 Vitis 应用 ELF，也未上板。具体证据见 reports/validation.md。

在 Vivado 2025.2 命令环境中、仓库根目录运行：

```powershell
vivado -mode batch -source build/create_project.tcl
# 检查新建工程中的 BD、DDR/MIO、参数和 XDC，再执行：
vivado -mode batch -source build/build.tcl
```

生成工程位于 work/，XSA 位于 artifacts/，资源/时序/DRC 报告位于 reports/。默认并行任务数为 4，可按电脑资源调整。脚本在已经有同名工程时拒绝覆盖；重构建可在该工程内重新运行所需步骤。脚本退出成功仍需人工检查报告中的时序、Critical Warning、未约束外设路径和实际板卡配置。

手工方式：新建 xc7z020clg484-1 工程，加入 src/rtl 全部 21 个 .v 和 board/xdc 两份 .xdc，导入 board/bd/camera.bd；刷新 model_camera_top_0，设置 ENABLE_PREVIEW=1、VAD_ABS_FRAME_ENERGY=6000、VAD_NOISE_MULT_SHIFT=1、VAD_STOP_MULT_SHIFT=0；保留原 PS/DDR/MIO 连线与 0x43C00000 / 512 KiB 地址。验证 BD、生成输出产品和 camera_wrapper 顶层，综合、实现、bit、导出含 bit 的 XSA。

Vitis 平台/应用重建步骤见 ../board/README.md。本次新 bit 位于 ../test/build/work/hearing_vision_fpga.runs/impl_1/camera_wrapper.bit，新 XSA 位于 ../test/build/artifacts/hearing_vision_fpga.xsa；已核对 XSA 内 bit 与实现 bit 完全一致。二进制和生成工程保留在测试目录，发布目录收录实际报告、日志和哈希清单。
