# 验证记录

以下为原作者的历史验证记录，出现的本机目录名只用于追溯当时输入，不是使用要求。其他人应按 README 指定自己的实际路径。未烧写硬件、未构建新 bit/XSA。
## 本次实际执行

| 检查 | 结果 | 证明范围 |
|---|---|---|
| quick_validate.py 格式检查 | 输出 Skill is valid! | SKILL.md 名称/frontmatter 格式检查；不证明工作流效果 |
| model_camera_vad_tb | PASS | 精确 6000/3000 边界、2/1 倍噪声门限、5/35 连续计数、顶层参数贯通与旧参数回退 |
| model_camera_servo_direction_tb | PASS | 镜像八方向、LED 坐标保留、中位、后方最近端点/等距左侧、PWM 范围、锁定、空闲回中和振动 |
| model_camera_alert_policy_tb | PASS | 120 秒提醒策略、静音/未知方向分支及声音证据、运动编号、运动/锁定、重复、分数等保护 |
| 实现 bit / XSA 内 bit / 调试 bit | SHA-256 全部相同 | 仅证明给定文件字节一致，不证明它们包含最新源码或已下载到板上 |
| tests/test_helpers.py | 当前发布包 9 tests，OK，无跳过项 | 检查脚本的正常路径、典型失效路径及改名目录中的实际 RTL 仿真，详见下文 |

运行环境：Windows PowerShell；Python 3；Icarus Verilog/vvp 0.9.7。本机旧 Icarus 不支持 -g2012，脚本已使用本案例所需的 -g2005。其他项目若依赖 SystemVerilog 或厂商 IP，需自行更换编译选项与仿真工具。

三份 bit 的 SHA-256：

```text
57acbde1c40dded1ebb245b8dd4a850de104ee30fba8c45ee100d14bef23d4f3
```

历史输入位置（仅记录原作者当时的目录布局，不是通用运行命令）：

```text
../integrate/vivado/model_camera.runs/impl_1/camera_wrapper.bit
../integrate/vivado/model_camera.xsa/model_camera.bit
../integrate/vitis/integrate_app/_ide/bitstream/model_camera.bit
```

历史工具行为测试覆盖：相同 bit 通过、旧调试 bit 拒绝、XSA 无 bit 拒绝、多 bit 时须指定包内路径、退出码 0 但有 FAIL 仍失败、出现 ERROR 后又打印 PASS 仍失败、无明确 PASS 失败、正常 PASS 通过。工具测试使用临时合成文件，不作为实物功能验收结果。

复查：原 11 项工具测试、三项 RTL 回归和 bit 哈希核对再次通过。修正 README 中发布到仓库根目录后的命令用法，明确脚本的路径起点，并补上 ERROR 日志拒绝检查。修改后 12 项工具测试和三项 RTL 回归均通过。

目录迁移复查：通用使用说明不再依赖原作者的目录名；回归脚本新增 --rtl-dir，可指定任意名字的 RTL 目录。当时新增第 13 项测试：将完整技能包复制到名称含空格的临时目录，创建名称不同的工程和源码目录，使用自定义 testbench 检查简单组合逻辑的两个输入，按相对路径调用复制后的脚本，实际仿真通过。当时 13 项工具测试均通过；这验证路径处理，不代表其他板卡的硬件验证。

当前包清理复查：仅保留 FPGA 复现与排错技能及其测试，移除不再发布的附加技能文件和对应 4 项测试；重新执行剩余 9 项工具测试，全部通过，无跳过项。上面的 11、12、13 项为先前版本的历史记录，不是当前测试数量。

## 复跑

按 README 使用自己的实际工程路径、RTL 目录、testbench 和构建产物。工具行为测试只需 Python 标准库；RTL 回归另需 iverilog/vvp。复跑原案例还需要原案例源码和三份 testbench，但不要求它们所在的工程文件夹叫特定名字。默认案例回归不适用于任意新题目。

## 未验证与参赛边界

- 没有重新综合/实现，未声明最新 RTL 与现有 bit 一致；原案例文档中待重建、待上板的配置仍需实际完成。
- 没有读取实物寄存器、测量机械行程/温升、现场 VAD/模型准确率或端到端耗时。
- 提示词与排错表从工程材料提炼，尚无陌生团队的独立复用试验。
- 根目录许可证、第三方许可、完整构建脚本、设计报告与真实协作/上板证据仍由项目提交者整理。
