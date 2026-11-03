# 可复用技能包

## 技能与边界

| 技能/材料 | 适用范围 | 使用方法 | 失效条件 | 验证效果与来源 |
|---|---|---|---|---|
| [fpga-reproduce](fpga-reproduce/SKILL.md)：提示词工作流 | Vivado/Vitis 工程的构建变更判断、复现诊断 | 按 references/workflow.md 提供自己的工程和板卡信息 | 缺板卡资料、工具版本或实测证据时只能输出待确认项 | 从 RTL 改了但 bit 未更新、旧 ELF 地址继续使用、预览图被误认成推理成功等观察提炼；本次可执行验证见 validation.md|
| fpga-reproduce：RTL 回归脚本 | Verilog 2005 工程，使用自己的 RTL、testbench 和顶层 | 按下面的命令指定工程、RTL 目录和 testbench 的实际路径 | 不支持 Icarus 的厂商原语/加密 IP；没有行为 testbench 则不能判断功能 | 检查退出码、FAIL/FATAL/ERROR 和明确 PASS，避免 testbench 用 $finish 报错却返回 0 的假通过 |
| fpga-reproduce：bit/XSA/调试 bit 核对 | 任意以 ZIP 格式导出且包含 .bit 的 XSA | 见下方命令 | 无 bit 的 XSA、多 bit 未指定成员、不同打包格式；哈希一致也不能证明 RTL 是最新或板上已经加载 | 对应调试缓存旧 bit 的排错经验；仅核对所给文件的字节一致性 |
| fpga-reproduce：排错清单/复用报告模板 | Zynq 软硬件联调，其他 FPGA 可取通用部分 | references/workflow.md、assets/reproduction-report.md | 模板不能替代实际资源、时序、准确率和上板测量 | 把方向反转、VAD 噪声门控、窗口/运动编号、外设未约束路径的观察转成检查步骤 |

## 使用方法

工程目录和克隆下来的仓库可以使用任意名字。把完整 skill/ 放到仓库根目录，在该根目录打开终端。命令中的 skill/... 是随包提供的脚本位置；引号里的中文是占位说明，运行前必须替换成你自己的实际路径或模块名，路径含空格时保留引号。输入路径可以是绝对路径，也可以相对于当前终端目录；不相对于脚本目录。若将技能包单独放在其他位置，改用脚本的实际路径调用即可。

需要 Python 3.10+；RTL 仿真另需 PATH 中的 iverilog、vvp，支持范围为 Verilog 2005。

### 1. 检查自己的 RTL

```powershell
python skill/fpga-reproduce/scripts/run_regression.py --root "工程根目录的实际路径" --rtl-dir "RTL源码目录的实际路径" --top "testbench顶层模块名" --tb "testbench文件的实际路径"
```

--root 是仿真的工作目录，可包含仿真读取的数据文件。--rtl-dir 读取指定目录直接包含的 .v 文件，不递归搜索；未指定时才默认读取工程根目录下的 rtl/。--tb 可以重复指定多个文件。testbench 必须在检查成功时打印以 PASS 开头的行，失败时打印 FAIL/FATAL/ERROR 或以非零退出码结束。

本包还保留原案例的三项回归作为默认模式：只有使用包含 tests/model_camera_vad_tb.v、tests/model_camera_servo_direction_tb.v、tests/model_camera_alert_policy_tb.v 的案例工程时，才可省略 --top 和 --tb。新题目应明确指定自己的 testbench。

### 2. 比较自己的构建产物

```powershell
python skill/fpga-reproduce/scripts/check_bit_chain.py --bit "实现生成的bit文件实际路径" --xsa "包含bit的XSA文件实际路径" --debug-bit "调试时加载的bit文件实际路径"
```

无需使用特定的工程名或文件名；这些文件必须已存在。--debug-bit 可省略，此时只比较实现 bit 与 XSA 包内的 bit；XSA 包含多个 bit 时，用 --member 指定要比较的 bit 在包内的完整路径。

### 3. 验证技能工具本身

```powershell
python -B -m unittest discover -s skill/tests -v
```

工具测试不需要原作者的 FPGA 工程。若已安装 iverilog/vvp，还会运行一项使用临时小型工程的目录迁移仿真；未安装时只跳过该项，其余测试只需 Python 标准库。脚本不构建 Vivado、不烧写板卡、不联网；回归临时产物自动清理。退出码 0 表示该脚本定义的检查通过；其他退出码表示失败。脚本输出可以保存为报告附件。

## 换板、换题和其他人使用

1. 复制整个 skill/ 到自己的项目；使用 Python 即可运行检查脚本，路径参数可以替换。
2. 给助手使用时，先让它读取对应 SKILL.md，按模板提交自己的板卡、时钟、工具版本、外设、地址图、输入输出与证据；也可按所用助手的技能安装方式安装子目录。本次没有安装到全局环境。
3. 换板必须替换器件、PS/DDR/MIO 配置、XDC 引脚/电压/时钟、复位及外设参数，并重新构建和上板。相同 xc7z020 器件不等于同一块板。
4. 裸 FPGA 可用回归、文件核对、提示词和排错方法；不能直接运行本工程 Cortex-A9 裸机程序。Zynq UltraScale+ 需要调整 CPU/BSP/ABI/地址与平台。非 AMD 平台不适用 XSA 核对流程。
5. 本工程采用 Vitis standalone 裸机程序。换板后须建立与目标板匹配的硬件设计和软件平台，重新构建并实际验证。

## 来源、证据与参赛状态

- 案例经验来自原项目的 README.md、REGISTER_MAP.md、RTL、testbench 和 VAD 配置脚本；这些是历史案例来源，不是其他项目必须拥有的文件或目录。复用时提供自己的工程输入，当前参数须和自己的源码、BD、实际加载产物分别核对。
- 具体观察：VAD 6000 与 2/1 倍噪声参数、舵机反向安装和后方端点、旧 ELF 权重/ready 地址、调试 bit 缓存、flags=2 测试图、10 帧中至少 1 帧 VAD 证据、120 秒延后提醒。通用方法不把这些数值设成其他项目的默认值。
- [validation.md](validation.md) 区分本次执行结果和历史文档记载。其他队伍复用效果、当前源码对应新硬件的现场准确率仍待验证。
- 根目录开源协议和第三方授权由项目发布者确认。此技能包不改变已有 RTL、权重、第三方 IP 的许可。
