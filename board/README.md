# 上板与现有材料

bd/camera.bd 保留当前板卡 PS/DDR/MIO、AXI 和外设连接；xdc/ 为已有两份引脚约束。photos/ 来自本地 media 的已有实物照片，不能单独作为最新源码准确率或上板成功的证据。尚未附有固件版本和场景标注的完整实测日志。

## Vitis 2025.2

1. 从重新生成且含 bit 的 XSA 新建 standalone / ps7_cortexa9_0 平台，再建空 C 应用。
2. 加入 src/ps 的 4 个 C 和 4 个头文件，移除额外模板 main。程序入口 model_camera_live.c。
3. 编译采用 -O3、-ffp-contract=off；宏 MODEL_CAMERA_PREVIEW=1、MODEL_LIVE_SEND_ALL=1、MODEL_CAMERA_VISUAL_ONLY=0；链接数学库 m，浮点 ABI 与 BSP 一致。历史工程还使用 -g3 和取消定义 __clang__，按工具链核对。
4. 使用 Vitis 生成链接脚本，将程序、BSS、权重缓存及工作区放入实际可用 DDR，建议至少预留 64 MiB。主栈/堆参考均为 0x2000；不要直接套用历史 1 GiB DDR 链接区域到较小内存板卡。
5. 构建 ELF，加载匹配的新 bit 和 PS 初始化文件。在 model_camera_wait() 断点处，从当前 ELF 符号/启动日志取得两个 blob 与 ready 的真实地址。
6. XSDB 执行 dow -data {仓库绝对路径/data/weights/model_weights.bin} <visual_blob地址>，以及 dow -data {仓库绝对路径/data/weights/model_face_weights.bin} <face_blob地址>。替换占位路径/地址，取消断点，执行 mwr <ready地址> 1 和 con。
7. 断电或重新加载 bit 后重新启动 ARM、加载权重，采集方向、无人脸/有人脸、静默/说话等场景结果。分数、声音证据、视角/运动编号等共同决定提醒。

## 可选收图与能量采样

电脑收图使用 tools/model_receive.py，921600 波特率。PS 日志串口与测试图像串口不同。flags=2 是无分数测试图，不等于推理成功；软件只接收板端结果。

mic_energy_test.tcl 是现有 XSDB 采样工具。加载本次新 6000、2 倍噪声启动配置后，先在 XSDB source 此脚本，再调用 mic_energy_test quiet 6000 2 或 mic_energy_test speech 6000 2；未加载新硬件时不要用推算门限冒充实际参数。脚本输出 CSV 到当前工作目录，归档时放入 data/samples 并补充场景和版本。

舵机物理行程/温升、实物 VAD 与视觉准确率、耗时仍待验收；历史说明已有发热记录。J3 水平舵机，J5 信号保持低；真实接线以 XDC 和实物板卡为准。
