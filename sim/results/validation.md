# 发布目录验证记录

执行位置：本发布目录根目录，Windows PowerShell、Python、Icarus Verilog/vvp。

实际执行 `python -B sim/run_regression.py`，退出码 0，三项均打印明确 PASS：

| 测试 | 结果 | 范围 |
|---|---|---|
| model_camera_vad_tb | PASS | 6000/3000 边界、2/1 倍噪声门限、5/35 连续窗口、顶层贯通与旧参数回退 |
| model_camera_servo_direction_tb | PASS | 八方向反向校准、中位、后方最近端点、PWM 范围、视角锁定、空闲回中、振动 |
| model_camera_alert_policy_tb | PASS | 120 秒提醒、静默/未知方向分支、声音证据/运动编号/锁定/重复等保护 |

实际执行 `python -B -m unittest discover -s skill/tests -v`，9 项测试全部通过，无跳过，退出码 0；包含临时改名目录下真实 RTL 仿真及 bit/XSA 文件检查的成功/失败路径。测试用的 bit/XSA 是合成样本，不是本工程的新硬件结果。

上述为 RTL 仿真和工具测试记录。另已在独立测试副本中完成 Vivado 工程创建、综合、实现和 bit/XSA 导出，见 ../../build/reports/validation.md。尚未重建 Vitis 应用或上板，未测量准确率、延迟、行程和温升。以上不代表最新源码已加载到实物。
