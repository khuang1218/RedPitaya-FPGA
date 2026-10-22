# Source in the routed implementation used by the measured v9 bitstream.
# Writes reports only: does not change placement, timing exceptions or runs.
# Optional output override before sourcing:
#   set tdc_fall_region_dir {C:/path/to/new/report/directory}

proc tdc_fall_region_reports {directory} {
    set design [current_design -quiet]
    if {[llength $design] != 1} {
        error "Open the routed implemented design before sourcing this script."
    }
    set carries [lsort -dictionary [get_cells -quiet -hierarchical -filter \
        {REF_NAME == CARRY4 && NAME =~ *i_tdc/i_width/i_fall_carry/*}]]
    set taps [lsort -dictionary [get_cells -quiet -hierarchical -filter \
        {REF_NAME == FDRE && NAME =~ *i_tdc/i_width/i_fall_carry/gen_tap*i_tap_ff}]]
    if {[llength $carries] != 128 || [llength $taps] != 512} {
        error "Expected v9 falling chain: 128 carries / 512 tap FFs; got [llength $carries] / [llength $taps]."
    }
    set directory [file normalize $directory]
    file mkdir $directory
    set summary [open [file join $directory summary.txt] w]
    set placement [open [file join $directory placement.tsv] w]
    set delays [open [file join $directory net_delays_ps.tsv] w]
    set status [catch {
        puts $summary "Design: $design"
        puts $summary "Tool: [version -short]"
        puts $summary "Created: [clock format [clock seconds]]"
        puts $summary "Inspect taps 84..108, including missing-code neighbourhoods 91..93 and 99..101."
        puts $summary "Net delay values are modelled picoseconds, including intra-site delay."
        puts $summary "C-pin net delay is not total clock insertion; inspect the expanded launch clock in q_to_pipeline reports."
        puts $summary "Data-input reports explicitly request user-ignored paths because tap D inputs are false-pathed."
        puts $summary "No timing exception is removed or modified. Empty reports do not mean zero delay."
        puts $placement "kind\tindex\tcell\tLOC\tBEL\tclock_region"
        puts $delays "tap\tpin_role\tpin\tdelay_object\tFAST_MIN_ps\tFAST_MAX_ps\tSLOW_MIN_ps\tSLOW_MAX_ps"

        # Use an exact NAME filter: Tcl braces preserve the literal bus index.
        set event_port [get_ports -quiet -filter {NAME == "exp_p_io[2]"}]
        puts $summary "Single-ended external input port: $event_port"

        for {set stage 21} {$stage <= 27} {incr stage} {
            set cell [lindex $carries $stage]
            set name [get_property NAME $cell]
            if {![regexp {gen_carry\[([0-9]+)\]} $name -> actual] || $actual != $stage} {
                error "Carry ordering does not match stage $stage: $name"
            }
            set site [get_sites -quiet -of_objects $cell]
            set region [get_clock_regions -quiet -of_objects $site]
            puts $placement [join [list CARRY4 $stage $name [get_property LOC $cell] \
                [get_property BEL $cell] $region] "\t"]
        }

        for {set index 84} {$index <= 108} {incr index} {
            set cell [lindex $taps $index]
            set name [get_property NAME $cell]
            if {![regexp {gen_tap\[([0-9]+)\]} $name -> actual] || $actual != $index} {
                error "Tap ordering does not match index $index: $name"
            }
            set site [get_sites -quiet -of_objects $cell]
            set region [get_clock_regions -quiet -of_objects $site]
            puts $placement [join [list FDRE $index $name [get_property LOC $cell] \
                [get_property BEL $cell] $region] "\t"]

            foreach role {D C} {
                set pin [get_pins -quiet -of_objects $cell -filter "REF_PIN_NAME == $role"]
                if {[llength $pin] != 1} {
                    puts $summary "Tap $index: expected one $role pin; found [llength $pin]."
                    continue
                }
                set nets [get_nets -quiet -of_objects $pin]
                if {[catch {get_net_delays -of_objects $nets -to $pin} objects]} {
                    puts $summary "Tap $index $role net-delay query failed: $objects"
                } elseif {[llength $objects] == 0} {
                    puts $summary "Tap $index $role: no net-delay objects."
                } else {
                    foreach object $objects {
                        puts $delays [join [list $index $role $pin $object \
                            [get_property FAST_MIN $object] [get_property FAST_MAX $object] \
                            [get_property SLOW_MIN $object] [get_property SLOW_MAX $object]] "\t"]
                    }
                }
            }

            set q [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == Q}]
            if {[llength $q] == 1} {
                # Q->pipeline is a normally timed path. Its launch clock path
                # reveals clock arrival at the physical sampling flip-flop.
                set output [file join $directory [format {q_to_pipeline_tap_%03d.rpt} $index]]
                if {[catch {report_timing -from $q -delay_type max -max_paths 1 \
                    -path_type full_clock_expanded -input_pins -file $output} message]} {
                    puts $summary "Tap $index Q timing report failed: $message"
                }
            }

            set d [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == D}]
            if {[llength $event_port] == 1 && [llength $d] == 1} {
                # External FALL becomes a rising edge in i_fall_carry.
                set output [file join $directory [format {async_data_to_tap_%03d.rpt} $index]]
                if {[catch {report_timing -fall_from $event_port -rise_to $d \
                    -user_ignored -delay_type max -max_paths 1 \
                    -path_type full_clock_expanded -input_pins -file $output} message]} {
                    puts $summary "Tap $index asynchronous data report failed: $message"
                }
            } else {
                puts $summary "Tap $index: skipped async report; external port or D pin was not unique."
            }
        }
    } result options]
    close $summary
    close $placement
    close $delays
    if {$status} {
        return -options $options $result
    }
    puts "Falling-chain region reports written to: $directory"
    puts "Review summary.txt for skipped/failed queries; these reports are modelled timing, not hardware calibration."
}

if {![info exists tdc_fall_region_dir]} {
    set tdc_fall_region_dir [file join [get_property DIRECTORY [current_project]] \
        tdc_fall_region_[clock format [clock seconds] -format %Y%m%d_%H%M%S]]
}
tdc_fall_region_reports $tdc_fall_region_dir
