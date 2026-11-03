# 仿真

在仓库根目录运行：

```powershell
python -B sim/run_regression.py
```

需要 Python 3.10+、iverilog、vvp。入口调用 skill 中已有的回归工具，使用 src/rtl 和 sim/tb 的实际路径。检查 VAD、舵机方向和 AXI 提醒规则；不会生成硬件或烧写板卡。结果见 results/validation.md。
