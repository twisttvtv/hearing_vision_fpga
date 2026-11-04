---
name: fpga-reproduce
description: Diagnose and reproduce Vivado/Vitis FPGA projects using change-impact analysis, RTL regression, bit/XSA consistency checks and evidence-based bring-up. Use for FPGA integration or board migration; not for claiming hardware validation from simulation alone.
---

# FPGA 复现与联调

先取得用户项目根目录、实际板卡型号/器件、工具版本、时钟、外设和本次变更。缺少板卡信息时继续做离线检查，把依赖实物的结论列为待确认，不能从器件号推断整板配置。

根据任务读取 [references/workflow.md](references/workflow.md)：包含变更影响判断、提示词模板和带触发条件的排错表。输出报告可使用 [assets/reproduction-report.md](assets/reproduction-report.md)，保留未测项。

执行所需检查：

下面的 scripts/ 路径以本 SKILL.md 所在目录为起点；从其他目录调用时，使用脚本的完整路径。--root 及 --tb 的相对路径以命令的当前工作目录为起点。

- RTL 行为回归：`python scripts/run_regression.py --root "工程实际路径" --rtl-dir "RTL目录实际路径" --top "测试顶层模块名" --tb "testbench实际路径"`。引号内是需替换的占位说明。--rtl-dir 指定直接包含 .v 文件的目录；省略时默认读取工程的 rtl/。--tb 可重复指定，testbench 应遵循 README 的 PASS/FAIL/FATAL/ERROR 日志约定。只有保留 tests/ 布局的原案例工程才可省略 --top 和 --tb，运行默认三项案例回归；当前发布案例位于 sim/tb/，应从仓库根目录运行 `python -B sim/run_regression.py`，该入口已显式指定所有路径；不能拿默认 testbench 名称要求新题目。厂商 IP 必须使用对应仿真库/仿真器，不能用空壳替代功能验收。
- 比较构建产物：`python scripts/check_bit_chain.py --bit FILE --xsa FILE --debug-bit FILE`。多 bit 的 XSA 用 `--member ZIP_ENTRY` 显式选择；只接受哈希完全相同。用于其他工程时替换所有文件参数。

把“源码已改、BD 参数已更新、bit/XSA 已重建、Vitis 已更新、板上已加载、实物已验证”分开记录。哈希只能证明文件一致；PASS 只能证明 testbench 覆盖的行为。资源/时序使用本次构建报告，还要检查未约束路径与外设 I/O，不能引用旧报告证明新源码。

修改硬件后需按项目要求重启处理器和重新加载权重，避免跨 PL 复位使用旧缓存。ELF 重建后从实际符号/启动日志获取权重和 ready 地址。报告最终给出执行命令、输入文件、结果、失败定位和仍未验证的边界，不补造协作历史或性能数据。
