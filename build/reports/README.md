# 综合与实现报告

这里收录独立测试副本使用 Vivado 2025.2 实际生成的报告：

- validation.md：执行步骤、结果和验证边界。
- utilization.rpt：资源占用。
- timing_summary.rpt：时序及未完整约束的外设接口。
- drc.rpt、methodology.rpt：设计规则和方法学检查。
- bus_skew.rpt、route_status.rpt：总线偏斜和布线检查。
- create_project_output.txt、build_output.txt：两份脚本的实际执行日志。
- input_manifest.csv：实际执行时的 26 个硬件构建输入及 SHA-256。
- artifacts.json：新 bit/XSA 的位置、哈希和关键结果。

自动生成的原始报告与日志保留工具原始元数据。生成工程和二进制位于同级 ../test 中，未加入源码发布目录。
