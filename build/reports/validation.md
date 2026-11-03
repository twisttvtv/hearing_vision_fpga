# Vivado 构建验证

在发布目录同级的 `../test` 中复制发布文件，使用 Vivado 2025.2、器件 `xc7z020clg484-1` 实际执行：

```powershell
vivado -mode batch -source build/create_project.tcl -log create_project_retry.log -journal create_project_retry.jou
vivado -mode batch -source build/build.tcl -log build.log -journal build.jou
```

本机实际调用程序为 `D:/vitis/2025.2/Vivado/bin/vivado.bat`。首次沙箱运行无法加载用户目录的 Tcl 初始化包；保留首次失败工程后，在获准的环境中重试成功，没有修改 Vivado 安装或用户配置。

| 检查 | 实际结果 |
|---|---|
| create_project.tcl | 退出码 0；新工程、BD 输出、camera_wrapper 生成成功 |
| build.tcl | 退出码 0；综合、实现、bitstream 和含 bit 的 XSA 导出成功 |
| 源码及板卡设置 | 测试副本 RTL、原始 BD、XDC 与发布输入一致；导入后外部端口、PS/DDR 和复位配置保留 |
| 当前模块参数 | ENABLE_PREVIEW=1、VAD_ABS_FRAME_ENERGY=6000、VAD_NOISE_MULT_SHIFT=1、VAD_STOP_MULT_SHIFT=0 |
| 已约束路径时序 | WNS=0.333 ns、WHS=0.043 ns；建立/保持失败端点均为 0 |
| 总线偏斜 | 5 项约束全部满足，最小裕量 8.760 ns |
| 布线 | 9969 条可布线网络全部布通，布线错误 0 |
| bitstream 前 DRC | 0 Errors；存在警告，详见原始报告 |
| 资源 | LUT 4949/53200，寄存器 5310/106400，BRAM 72/140，DSP 9/220 |
| XSA 内 bit | 与实现生成的 camera_wrapper.bit 逐字节一致；哈希见 artifacts.json |

验证完成后，发布脚本只更新了首行注释，Tcl 执行命令保持不变；input_manifest.csv 记录实跑时的输入哈希。生成产物保留在 ../test，原开发工程没有被覆盖。

## 保留的限制

时序通过仅适用于已提供的约束。报告仍列出 12 个未指定输入延时的输入、1 个已有 false path 的输入，以及 17 个未指定输出延时的端口；存在 DSP 流水线、BRAM 异步控制、时钟布局、I/O 缓冲等警告，没有通过降级 DRC 或伪造外设时序参数来消除这些提示。

本次验证两份 Vivado 脚本，未新建 Vitis 平台/应用或生成新 ELF，未下载板卡，也未验证机械行程、温升、识别准确率和端到端耗时。上板前需要从本次 XSA 建立或更新平台、重建应用并加载匹配的 bit/ELF 和权重。
