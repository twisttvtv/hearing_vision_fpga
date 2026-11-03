# 权重与历史采样

weights/model_face_weights.bin（210264 字节）为 YuNet 检测图/权重；weights/model_weights.bin（2181192 字节）为 Light-ASD 已训练视觉分支导出权重。两份均为已有板端运行输入，未在本次重新训练或导出。第三方授权说明及原文见 [第三方授权说明](../report/licenses/README.md)。

samples/ 的 quiet/speech 两份 CSV 是已有历史能量测试，原采样固件、距离和环境未完整标注。本次未重新采集，不视作最新 6000/2 配置的验收结果。未包含 AVA 数据集、训练缓存和大视频；当前板端运行不依赖它们。
