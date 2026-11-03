# Run after create_project.tcl and reviewing the imported board configuration.
set hv_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $hv_root build work hearing_vision_fpga.xpr]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {![string match {*Complete*} [get_property STATUS [get_runs synth_1]]]} { error "Synthesis did not complete" }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {![string match {*write_bitstream Complete*} [get_property STATUS [get_runs impl_1]]]} { error "Bitstream run did not complete" }
open_run impl_1
file mkdir [file join $hv_root build reports]
file mkdir [file join $hv_root build artifacts]
report_utilization -file [file join $hv_root build reports utilization.rpt]
report_timing_summary -file [file join $hv_root build reports timing_summary.rpt]
report_drc -file [file join $hv_root build reports drc.rpt]
write_hw_platform -fixed -include_bit -force -file [file join $hv_root build artifacts hearing_vision_fpga.xsa]
puts "XSA exported. Review reports, including unconstrained interfaces; then build Vitis and validate on board."
