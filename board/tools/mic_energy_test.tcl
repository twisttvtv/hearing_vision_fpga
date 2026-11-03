# Run from the existing XSDB console. This script only reads PL registers.
# source {D:/FPGA/hearing_vision/integrate/tools/mic_energy_test.tcl}
# mic_energy_test quiet
# mic_energy_test speech
# After loading the new 6000 / 2x FPGA build, use:
# mic_energy_test quiet 6000 2
# mic_energy_test speech 6000 2

namespace eval mc_energy {
    variable output_dir [file dirname [info script]]
    # Current integrate BD parameters. Values below are FPGA energy units.
    variable absolute_start 30720
    variable noise_multiplier 8
}

proc mc_energy::read32 {address} {
    set words [mrd -value $address 1]
    # XSDB mrd -value returns Tcl integers from binary scan, not display hex.
    if {[llength $words] != 1 || ![string is entier -strict [lindex $words 0]]} {
        error "Invalid register response at [format 0x%08X $address]: $words"
    }
    set value [lindex $words 0]
    return [expr {$value & 0xFFFFFFFF}]
}

proc mc_energy::read48 {low_address} {
    set high_address [expr {$low_address + 4}]
    for {set attempt 0} {$attempt < 4} {incr attempt} {
        set high1 [read32 $high_address]
        set low [read32 $low_address]
        set high2 [read32 $high_address]
        if {$high1 == $high2} {
            return [expr {(($high1 & 0xFFFF) << 32) | $low}]
        }
    }
    error "Register changed during read; repeat the test."
}

proc mic_energy_test {mode {absolute_start ""} {noise_multiplier ""}} {
    if {$mode ni {quiet speech}} {error "Use: mic_energy_test quiet OR mic_energy_test speech"}
    if {$absolute_start eq ""} {set absolute_start $mc_energy::absolute_start}
    if {$noise_multiplier eq ""} {set noise_multiplier $mc_energy::noise_multiplier}
    if {![string is entier -strict $absolute_start] || $absolute_start <= 0 ||
        ![string is entier -strict $noise_multiplier] || $noise_multiplier <= 0} {
        error "Threshold and noise multiplier must be positive integers."
    }
    puts "MIC_ENERGY v2: checking FPGA ID..."
    flush stdout
    set fpga_id [mc_energy::read32 0x43C00000]
    if {$fpga_id != 0x4D434156} {
        error "Unexpected FPGA ID [format 0x%08X $fpga_id] (expected 0x4D434156); check the current target and bitstream."
    }
    set count 80
    set path [file join $mc_energy::output_dir mic_energy_${mode}.csv]
    puts "Mode=$mode. Keep the microphone distance and background unchanged."
    puts "Configured threshold=max($absolute_start, noise*$noise_multiplier); these settings must match the loaded FPGA bitstream."
    if {$mode eq "quiet"} {
        puts "Remain quiet during the entire measurement."
    } else {
        puts "Speak continuously at normal volume during the entire measurement."
    }
    puts "Starting in 3 seconds. Sampling takes at least 8 seconds."
    flush stdout
    after 3000
    puts "Writing CSV: $path"
    flush stdout
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf -buffering line
    set energy_values {}
    set noise_values {}
    set active_count 0
    set above_count 0
    set begun [clock milliseconds]
    try {
        puts $channel "sample,elapsed_ms,energy,noise,configured_start_threshold,vad,direction_valid,moving,hold,status_hex"
        for {set i 0} {$i < $count} {incr i} {
            if {$i == 0} {puts "Reading first snapshot..."; flush stdout}
            set energy [mc_energy::read48 0x43C00090]
            set noise [mc_energy::read48 0x43C00098]
            set status [mc_energy::read32 0x43C00070]
            set threshold [expr {max($absolute_start, $noise * $noise_multiplier)}]
            set active [expr {$status & 1}]
            set direction [expr {($status >> 1) & 1}]
            set moving [expr {($status >> 2) & 1}]
            set hold [expr {($status >> 4) & 1}]
            set elapsed [expr {[clock milliseconds] - $begun}]
            puts $channel [join [list $i $elapsed $energy $noise $threshold $active $direction $moving $hold [format 0x%08X $status]] ,]
            lappend energy_values $energy
            lappend noise_values $noise
            incr active_count $active
            if {$energy > $threshold} {incr above_count}
            if {$i == 0 || ($i + 1) % 10 == 0} {
                puts "Collected [expr {$i+1}]/$count; energy=$energy noise=$noise VAD=$active"
                flush stdout
            }
            after 100
        }
    } finally {
        close $channel
    }
    set sorted [lsort -integer $energy_values]
    set noise_sorted [lsort -integer $noise_values]
    puts "RESULT mode=$mode samples=$count elapsed_ms=[expr {[clock milliseconds]-$begun}]"
    puts "Energy: min=[lindex $sorted 0] median=[lindex $sorted 40] p95=[lindex $sorted 75] max=[lindex $sorted end]"
    puts "Noise: median=[lindex $noise_sorted 40] max=[lindex $noise_sorted end]"
    puts "VAD active: $active_count/$count; energy above configured start threshold: $above_count/$count"
    puts "CSV: $path"
    puts "These are polled snapshots, not every audio hop. No sound level in dB is inferred."
    return $path
}

puts "MIC_ENERGY v2 loaded. Run mic_energy_test quiet, then mic_energy_test speech."
