# 第三方来源与授权范围

根目录 MIT 用于本项目有权许可的原创部分；第三方材料及派生内容保留原作者声明，不以本项目署名替代。

- Light-ASD：本地 model/README.md 标明纯视觉部分来自官方 visualEncoder 和已训练 lossV.FC；来源 https://github.com/Junhua-Liao/Light-ASD 。保留本地上游 MIT 原文 light_asd_license.txt，署名 Liao Junhua。data/weights/model_weights.bin 是现有导出文件；本次未重新核实其训练 checkpoint 的精确上游版本。
- YuNet：本地 model_face_export.py 指向 face_detection_yunet_2026may.onnx；保留 yunet_provenance.json 的原始 URL 和源 ONNX 哈希、yunet_license.txt 的 MIT 声明，署名 Shiqi Yu。该源 ONNX 的哈希不同于导出 .bin 的哈希。
- AMD/Xilinx：BD 引用 Vivado/Vitis 工具提供的 PS、AXI 等 IP，构建需要相应工具和原供应商许可；本包未复制生成 IP 实现、BSP 或工具安装文件，根 MIT 不替代其许可。

本次按本地已有来源/许可文件归档，不表示已完成所有历史素材的权属审计。发布时请维护者核对原创权属和实际采用的模型版本，并保留这些通知。
