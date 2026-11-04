# hearing_vision_fpga

基于 Zynq-7000 的听觉定位与视觉说话检测原型。四路麦克风经 PL 端 VAD/TDOA 确定声音候选和方向，驱动水平舵机转向；摄像头图像经 AXI 交给片上 Cortex-A9，在 ARM 裸机程序上运行 YuNet 人脸检测与 Light-ASD 纯视觉分支，结合声音证据和视角状态控制振动提醒。电脑工具仅接收测试图像和板端结果。

当前发布产物采用原 integrate 调试工程对应的 XSA、bit、ELF 和 PS 初始化脚本。另已在独立测试副本中完成源码的 Vivado 重建验证，记录保留在 build/reports/；当前下载文件与独立重建产物的哈希分别记录。当前软件窗口为 10 帧，至少 1 帧有效 VAD；历史说明中的 5/16 帧是旧实验。

## 目录对照

| 目录 | 内容及当前状态 |
|---|---|
| src/ | 21 个 RTL、8 个 ARM C/头文件及寄存器说明 |
| sim/ | 3 份现有 testbench、相对路径回归入口、实际复跑结果 |
| build/ | 新增 Vivado 工程重建/构建入口；脚本已在 Vivado 2025.2 实跑；reports/ 含实际报告 |
| board/ | BD、2 份 XDC、收图/采样工具、硬件照片及原工程配套 bit/XSA/ELF、PS 初始化脚本 |
| data/ | 2 份运行权重、2 份历史能量采样 CSV |
| skill/ | 已有 fpga-reproduce 技能包与工具测试 |
| report/ | 设计报告 design_report.pdf；大模型协作记录 ai_collaboration.md 与 ai_collaboration.pdf |

文件名使用英文和下划线/连字符；README.md、SKILL.md、LICENSE 保留工具与开源社区的常规命名。原开发工程、BSP、缓存、历史模型训练数据和大视频未包含。没有另外编造 HLS 或其他未实现的模块。

## 可下载的上板文件

已提供原 integrate 工程的 [bit](board/artifacts/hearing_vision_fpga.bit)、[含 bit 的 XSA](board/artifacts/hearing_vision_fpga.xsa)、[ELF](board/artifacts/integrate_app.elf) 和 [PS 初始化脚本](board/artifacts/ps7_init.tcl)。XSA 与原 Vitis 平台副本一致，bit 与原调试配置中的文件及 XSA 内 bit 一致；ELF 来自原调试配置指向的应用构建目录。路径与 SHA-256 见 [产物记录](build/reports/artifacts.json)，使用方式见 [上板说明](board/README.md)。

## 环境与快速复现

1. 安装 Vivado/Vitis 2025.2。器件 `xc7z020clg484-1`；板卡 DDR/MIO 和实物接线必须匹配随附 BD/XDC。摄像头为 OV5640，四路 INMP441，水平 270° 舵机与振动驱动模块。
2. 如需从源码重建硬件，在仓库根目录执行 `vivado -mode batch -source build/create_project.tcl`，或按 [build/README.md](build/README.md) 手动导入源码和 BD。脚本会创建 `build/work/` 中的新工程；该脚本已在 Vivado 2025.2 的独立测试副本中运行成功。
3. 重建硬件时，在 Vivado 中检查 BD/引脚/时钟，完成综合、实现和 bit，导出含 bit 的 XSA；入口为 `build/build.tcl`。查看实际生成的时序/DRC，不能把历史时序值当作最新结果。
4. 如需从源码重新编译，按 [board/README.md](board/README.md) 使用所选 XSA 建立 Vitis standalone 平台和空应用，加入 `src/ps/` 全部 8 个文件，使用规定编译设置生成 ELF；原工程已有 ELF 已随包提供。
5. 加载 board/artifacts/ 中配套的 bit/ELF，或自己重建的配套产物，在 `model_camera_wait()` 断点处，按当前 ELF 日志中的真实地址加载 `data/weights/` 的两份权重，设置 ready 后运行。
6. 可选电脑预览：安装 `pip install -r board/tools/requirements.txt`，执行 `python board/tools/model_receive.py --port COM7 --baud 921600`，按实际设备修改端口。

源码中的 `D:/FPGA/hearing_vision/integrate/weights/` 只是原电脑上打印的下载命令示例，不会由 ARM 打开该路径；换电脑后手动替换为本仓库 `data/weights/` 的绝对路径。`skill/validation.md` 中原电脑的路径/数字只用于历史追溯。

## 验证与发布状态

在仓库根目录运行 `python -B sim/run_regression.py` 复跑现有三项 RTL 回归；需要 Python 3.10+、iverilog/vvp。具体本次结果见 [sim/results/validation.md](sim/results/validation.md)。回归通过不代表板端准确率、温升、机械行程或端到端耗时已验收。

设计报告见 [design_report.pdf](report/design_report.pdf)。大模型协作记录见 [Markdown 版](report/ai_collaboration.md) 和 [PDF 版](report/ai_collaboration.pdf)。原创部分采用 [MIT](LICENSE)，第三方模型及其派生部分保留原作者授权，见 [模型授权说明](report/licenses/README.md)。
