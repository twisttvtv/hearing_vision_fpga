# Vivado 2025.2. Create a project from repository-relative inputs.
set hv_root [file normalize [file join [file dirname [info script]] ..]]
set hv_work [file join $hv_root build work]
if {[file exists [file join $hv_work hearing_vision_fpga.xpr]]} {
    error "Project already exists; open build/work/hearing_vision_fpga.xpr or choose a new work directory."
}
create_project hearing_vision_fpga $hv_work -part xc7z020clg484-1
set_property target_language Verilog [current_project]
add_files -norecurse [glob [file join $hv_root src rtl *.v]]
add_files -fileset constrs_1 -norecurse [glob [file join $hv_root board xdc *.xdc]]
# Import a project-local copy so generation and parameter updates leave the release BD untouched.
import_files -norecurse [file join $hv_root board bd camera.bd]
update_compile_order -fileset sources_1
set hv_bd [get_files -quiet */camera.bd]
if {[llength $hv_bd] != 1} { error "Expected exactly one imported camera.bd" }
open_bd_design $hv_bd
set hv_ip [get_ips -quiet -all camera_model_camera_top_0_0]
if {[llength $hv_ip] == 1} { update_module_reference -verbose $hv_ip }
set hv_cell [get_bd_cells model_camera_top_0]
set_property -dict [list CONFIG.ENABLE_PREVIEW 1 CONFIG.VAD_ABS_FRAME_ENERGY 6000 CONFIG.VAD_NOISE_MULT_SHIFT 1 CONFIG.VAD_STOP_MULT_SHIFT 0] $hv_cell
validate_bd_design
save_bd_design
generate_target all $hv_bd
set hv_wrapper [make_wrapper -files $hv_bd -top]
add_files -norecurse $hv_wrapper
set_property top camera_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "Created build/work/hearing_vision_fpga.xpr. Review BD/XDC before implementation."
