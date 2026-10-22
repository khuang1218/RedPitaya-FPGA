# Read-only reports for the October 21 v11 fine-code rejects.
# Source with the measured bitstream's routed implemented design open.
# No run, placement property, clock or timing exception is changed.
# Optional output override: set tdc_width_regions_dir {C:/path/to/reports}

proc tdc_width_regions_reports {directory} {
    if {[llength [current_design -quiet]] != 1} {
        error "Open the routed implemented design used by the measured bitstream."
    }
    set directory [file normalize $directory]
    file mkdir $directory
    set summary [open [file join $directory summary.txt] w]
    set placement [open [file join $directory placement.tsv] w]
    set delays [open [file join $directory net_delays_ps.tsv] w]
    set code [catch {
        puts $summary "Design: [current_design]; tool: [version -short]"
        puts $summary "Created: [clock format [clock seconds]]"
        puts $summary "RISE rejects: 82,166,174,206; FALL reject: 170. Also inspect tap-0 reference."
        puts $summary "Rejected indices are leading-prefix diagnostics, not full raw snapshots."
        puts $summary "Modelled delays do not prove hardware tap order or calibration accuracy."
        puts $summary "Net-delay properties are ps, not ns; do not add them to complete timing paths."
        puts $summary "Sampler D paths are user-ignored reports; no timing exceptions are changed."
        puts $placement "edge\ttap\tcarry\tcarry_LOC\tFF\tFF_LOC\tFF_BEL\tclock_region"
        puts $delays "edge\ttap\tpin_role\tpin\tdelay_object\tFAST_MIN_ps\tFAST_MAX_ps\tSLOW_MIN_ps\tSLOW_MAX_ps"
        set event_port [get_ports -quiet -filter {NAME == "exp_p_io[2]"}]
        puts $summary "External input: $event_port"
        foreach edge {RISE FALL} hierarchy {i_tdc/i_width/i_carry i_tdc/i_width/i_fall_carry} \
                ranges {{{0 8} {76 90} {160 182} {200 214}} {{0 8} {164 180}}} {
            set carries [lsort -dictionary [get_cells -quiet -hier -filter \
                "REF_NAME == CARRY4 && NAME =~ *$hierarchy/*"]]
            set taps [lsort -dictionary [get_cells -quiet -hier -filter \
                "REF_NAME == FDRE && NAME =~ *$hierarchy/gen_tap*i_tap_ff"]]
            if {[llength $carries]!=128 || [llength $taps]!=512} {
                error "$edge: expected 128 carries / 512 tap FFs; got [llength $carries] / [llength $taps]."
            }
            foreach range $ranges {
                lassign $range first last
                for {set index $first} {$index<=$last} {incr index} {
                    set tap [lindex $taps $index]
                    set carry [lindex $carries [expr {$index/4}]]
                    if {![regexp {gen_tap\[([0-9]+)\]} $tap -> actual] || $actual!=$index} {
                        error "$edge tap ordering mismatch at $index: $tap"
                    }
                    set ff_loc [get_property LOC $tap]
                    set carry_loc [get_property LOC $carry]
                    if {$ff_loc eq "" || $carry_loc eq ""} {
                        error "Unplaced $edge tap $index; open the routed implemented design."
                    }
                    set site [get_sites -quiet -of_objects $tap]
                    puts $placement [join [list $edge $index $carry $carry_loc $tap \
                        $ff_loc [get_property BEL $tap] [get_clock_regions -quiet -of_objects $site]] "\t"]
                    foreach role {D C} {
                        set pin [get_pins -quiet -of_objects $tap -filter "REF_PIN_NAME == $role"]
                        if {[llength $pin]!=1} { error "$edge tap $index: nonunique $role pin." }
                        set nets [get_nets -quiet -of_objects $pin]
                        if {[catch {get_net_delays -of_objects $nets -to $pin} objects]} {
                            puts $summary "$edge tap $index $role delay query failed: $objects"
                        } elseif {[llength $objects]==0} {
                            puts $summary "$edge tap $index $role: no net-delay objects."
                        } else {
                            foreach object $objects {
                                puts $delays [join [list $edge $index $role $pin $object \
                                    [get_property FAST_MIN $object] [get_property FAST_MAX $object] \
                                    [get_property SLOW_MIN $object] [get_property SLOW_MAX $object]] "\t"]
                            }
                        }
                    }
                    set q [get_pins -quiet -of_objects $tap -filter {REF_PIN_NAME == Q}]
                    set output [file join $directory [format {%s_q_to_pipeline_%03d.rpt} $edge $index]]
                    if {[catch {report_timing -from $q -delay_type max -max_paths 1 \
                        -path_type full_clock_expanded -input_pins -file $output} message]} {
                        puts $summary "$edge tap $index Q timing query failed: $message"
                    }
                    set d [get_pins -quiet -of_objects $tap -filter {REF_PIN_NAME == D}]
                    if {[llength $event_port]!=1} {
                        puts $summary "$edge tap $index: async data report skipped (input not unique)."
                        continue
                    }
                    set polarity [expr {$edge eq "RISE" ? "-rise_from" : "-fall_from"}]
                    foreach delay_type {max min} {
                        set output [file join $directory [format {%s_async_%s_%03d.rpt} $edge $delay_type $index]]
                        if {[catch {report_timing $polarity $event_port -rise_to $d \
                            -user_ignored -delay_type $delay_type -max_paths 1 \
                            -path_type full_clock_expanded -input_pins -file $output} message]} {
                            puts $summary "$edge tap $index async $delay_type query failed: $message"
                        }
                    }
                }
            }
        }
        if {[catch {report_timing -delay_type max -slack_lesser_than 0 -max_paths 200 \
            -nworst 1 -path_type full_clock_expanded -input_pins \
            -file [file join $directory failing_setup_endpoints.rpt]} message]} {
            puts $summary "Full failing-endpoint timing query failed: $message"
        }
    } result options]
    close $summary
    close $placement
    close $delays
    if {$code} { return -options $options $result }
    puts "Width regional reports written to: $directory"
    puts "Read summary.txt for skipped/failed queries. Reports are modelled timing, not hardware calibration."
}

if {![info exists tdc_width_regions_dir]} {
    set tdc_width_regions_dir [file join [get_property DIRECTORY [current_project]] \
        tdc_width_regions_[clock format [clock seconds] -format %Y%m%d_%H%M%S]]
}
tdc_width_regions_reports $tdc_width_regions_dir
