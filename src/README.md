# 源码

- rtl/：来自 integrate/rtl 的 21 个 Verilog，加入 Vivado Design Sources。
- ps/：来自 integrate/arm 的 4 个 C 与 4 个头文件，加入 Vitis 空应用。入口为 model_camera_live.c。
- register_map.md：现有 AXI 寄存器说明，基址 0x43C00000、地址范围 512 KiB。

不加入原独立 mic/servo/model 工程中的重复模块。整机综合顶层为 BD 自动生成的 camera_wrapper，不是 model_camera_top。源码保留原内容，历史电脑路径的适配见根 README。
