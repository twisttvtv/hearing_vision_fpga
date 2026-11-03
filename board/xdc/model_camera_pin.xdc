# 摄像头、麦克风与舵机约束。model_camera_top 的 AXI 留在 BD 内部；最终顶层为 PS wrapper。
# AXI 读接口与元数据连接片内 ARM，不能直接当外部 GPIO 分配。
set_property -dict {PACKAGE_PIN AA18 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 10.000 -name clk [get_ports clk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports clk]]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports rst_n]
set_property -dict {PACKAGE_PIN AB20 IOSTANDARD LVCMOS33} [get_ports cam_scl]
set_property -dict {PACKAGE_PIN AB19 IOSTANDARD LVCMOS33} [get_ports cam_sda]
set_property -dict {PACKAGE_PIN AA19 IOSTANDARD LVCMOS33} [get_ports cam_reset]
set_property -dict {PACKAGE_PIN Y21 IOSTANDARD LVCMOS33} [get_ports cam_pwdn]
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports cam_pclk]
set_property -dict {PACKAGE_PIN Y20 IOSTANDARD LVCMOS33} [get_ports cam_vsync]
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports cam_href]
set_property -dict {PACKAGE_PIN W21 IOSTANDARD LVCMOS33} [get_ports {cam_data[0]}]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports {cam_data[1]}]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {cam_data[2]}]
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports {cam_data[3]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {cam_data[4]}]
set_property -dict {PACKAGE_PIN AA22 IOSTANDARD LVCMOS33} [get_ports {cam_data[5]}]
set_property -dict {PACKAGE_PIN AB22 IOSTANDARD LVCMOS33} [get_ports {cam_data[6]}]
set_property -dict {PACKAGE_PIN AA21 IOSTANDARD LVCMOS33} [get_ports {cam_data[7]}]
create_clock -period 23.810 -name cam_pclk_clk [get_ports cam_pclk]
set_false_path -from [get_ports rst_n]

# 仅对真正的同步器/稳定数据邮箱定义 CDC 约束，不整组切断两个时钟。
# 正则保留任意 BD/wrapper 前缀；目标必须匹配到实际寄存器。
# XDC 不支持 if/llength 条件控制，约束直接应用到查询得到的对象。
set init_first [get_cells -hier -regexp {.*init_sync_reg\[0\]$} -filter {IS_SEQUENTIAL == 1}]
set_false_path -to [get_pins -of_objects $init_first -filter {REF_PIN_NAME == D}]
# 异步复位只在各域复位同步器入口豁免；后续逻辑由本域同步释放的复位驱动。
set reset_sync_cells [get_cells -hier -regexp {.*(cam_reset_sync_reg|camera_reset_sync_reg|write_reset_sync_reg|read_reset_sync_reg|io_reset_sync_reg)\[[0-9]+\]$} -filter {IS_SEQUENTIAL == 1}]
set_false_path -to [get_pins -of_objects $reset_sync_cells -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]

# Gray 总线的最大传播延时/位间偏斜均限为 10 ns；保留同步器之后的本域时序。
set time_target [get_cells -hier -regexp {.*u_sync/gray_ff1_reg\[[0-9]+\]$} -filter {IS_SEQUENTIAL == 1}]
# 由首级 D 的真实驱动寻找源，兼容 Gray 最高位与二进制计数器被综合合并。
set time_source [get_cells -of_objects [get_pins -of_objects [get_nets -of_objects [get_pins -of_objects $time_target -filter {REF_PIN_NAME == D}]] -filter {DIRECTION == OUT}] -filter {IS_SEQUENTIAL == 1}]
set_max_delay -datapath_only 10.000 -from $time_source -to $time_target
set_bus_skew 10.000 -from $time_source -to $time_target
set read_target [get_cells -hier -regexp {.*u_video_buffer/read_ff1_reg\[[0-9]+\]$} -filter {IS_SEQUENTIAL == 1}]
set read_source [get_cells -of_objects [get_pins -of_objects [get_nets -of_objects [get_pins -of_objects $read_target -filter {REF_PIN_NAME == D}]] -filter {DIRECTION == OUT}] -filter {IS_SEQUENTIAL == 1}]
set_max_delay -datapath_only 10.000 -from $read_source -to $read_target
set_bus_skew 10.000 -from $read_source -to $read_target
set write_target [get_cells -hier -regexp {.*u_video_buffer/write_ff1_reg\[[0-9]+\]$} -filter {IS_SEQUENTIAL == 1}]
set write_source [get_cells -of_objects [get_pins -of_objects [get_nets -of_objects [get_pins -of_objects $write_target -filter {REF_PIN_NAME == D}]] -filter {DIRECTION == OUT}] -filter {IS_SEQUENTIAL == 1}]
set_max_delay -datapath_only 10.000 -from $write_source -to $write_target
set_bus_skew 10.000 -from $write_source -to $write_target
set drop_target [get_cells -hier -regexp {.*u_video_buffer/drop_ff1_reg\[[0-9]+\]$} -filter {IS_SEQUENTIAL == 1}]
set drop_source [get_cells -of_objects [get_pins -of_objects [get_nets -of_objects [get_pins -of_objects $drop_target -filter {REF_PIN_NAME == D}]] -filter {DIRECTION == OUT}] -filter {IS_SEQUENTIAL == 1}]
set_max_delay -datapath_only 10.000 -from $drop_source -to $drop_target
set_bus_skew 10.000 -from $drop_source -to $drop_target
set error_target [get_cells -hier -regexp {.*u_video_buffer/error_ff1_reg\[[0-9]+\]$} -filter {IS_SEQUENTIAL == 1}]
set error_source [get_cells -of_objects [get_pins -of_objects [get_nets -of_objects [get_pins -of_objects $error_target -filter {REF_PIN_NAME == D}]] -filter {DIRECTION == OUT}] -filter {IS_SEQUENTIAL == 1}]
set_max_delay -datapath_only 10.000 -from $error_source -to $error_target
set_bus_skew 10.000 -from $error_source -to $error_target

# 元数据与帧指针一起构成稳定数据邮箱：整帧发布、两级指针同步后才锁存，释放前保持。
# 10 ns 小于两级指针同步所提供的稳定时间；这里不是对任意多位 CDC 放行。
set metadata_source [get_cells -hier -regexp {.*u_video_buffer/(time_meta_reg|sequence_meta_reg)\[[0-9]+\]\[[0-9]+\]$} -filter {IS_SEQUENTIAL == 1}]
set metadata_target [get_cells -hier -regexp {.*u_video_buffer/(head_time_reg|head_sequence_reg)\[[0-9]+\]$} -filter {IS_SEQUENTIAL == 1}]
set_max_delay -datapath_only 10.000 -from $metadata_source -to $metadata_target

# PS DDR/FIXED_IO 使用厂家 PS 配置；AXI 不能 Make External。

# Integrated mic/servo pins. Keep the shared active-low reset at H17.
# Do not also import mic's A22 reset or servo's reversed LED constraints.
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports mic_sck]
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports mic_ws]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports mic_sd_lr]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports mic_sd_ud]
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} [get_ports servo0]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports servo1]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports vib]
set_property -dict {PACKAGE_PIN H19 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN F21 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN B22 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN B21 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN D21 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN E20 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
