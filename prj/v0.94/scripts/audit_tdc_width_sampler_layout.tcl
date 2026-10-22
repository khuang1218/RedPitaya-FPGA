# Read-only physical audit. Source with a placed/routed design open.
# Works on v10 to diagnose displacement, and v11 to check the new macros.
# Does not run implementation, set properties, or change timing exceptions.
proc tdc_audit_width_sampler_layout {} {
    if {[llength [current_design -quiet]] != 1} { error "Open a placed or routed design first." }
    set directory [file join [get_property DIRECTORY [current_project]] \
        tdc_sampler_layout_[clock format [clock seconds] -format %Y%m%d_%H%M%S]]
    file mkdir $directory
    set handle [open [file join $directory placement.tsv] w]
    puts $handle "edge\ttap\tcarry_LOC\tFF_LOC\tFF_BEL\tcolocated\tcorrect_lane"
    set failures 0
    set unplaced 0
    set code [catch {
        foreach edge {RISE FALL} hierarchy {i_tdc/i_width/i_carry i_tdc/i_width/i_fall_carry} {
            set carries [lsort -dictionary [get_cells -quiet -hier -filter \
                "REF_NAME == CARRY4 && NAME =~ *$hierarchy/*"]]
            set taps [lsort -dictionary [get_cells -quiet -hier -filter \
                "REF_NAME == FDRE && NAME =~ *$hierarchy/gen_tap*i_tap_ff"]]
            if {[llength $carries]!=128 || [llength $taps]!=512} {
                error "${edge}: expected 128 carries / 512 tap FFs; found [llength $carries] / [llength $taps]."
            }
            set last_x ""
            set last_y -1
            for {set stage 0} {$stage<128} {incr stage} {
                set carry [lindex $carries $stage]
                if {![regexp {gen_carry\[([0-9]+)\]} $carry -> actual] || $actual!=$stage} {
                    error "$edge carry ordering mismatch at $stage: $carry"
                }
                set location [get_property LOC $carry]
                if {![regexp {^SLICE_X([0-9]+)Y([0-9]+)$} $location -> x y]} {
                    incr unplaced
                } else {
                    if {$stage>0 && ($x!=$last_x || $y!=$last_y+1)} {
                        puts "WARNING: $edge carry chain discontinuity at stage $stage ($location)."
                        incr failures
                    }
                    set last_x $x
                    set last_y $y
                }
                for {set lane 0} {$lane<4} {incr lane} {
                    set index [expr {$stage*4+$lane}]
                    set tap [lindex $taps $index]
                    if {![regexp {gen_tap\[([0-9]+)\]} $tap -> actual] || $actual!=$index} {
                        error "$edge tap ordering mismatch at $index: $tap"
                    }
                    set ff_location [get_property LOC $tap]
                    set ff_bel [get_property BEL $tap]
                    set colocated [expr {$location ne "" && $location eq $ff_location}]
                    # Vivado may return AFF, SLICEL.AFF, SLICEM.AFF or a
                    # site-qualified BEL. Keep the raw value in the report,
                    # but compare the leaf name after '/' or '.'.
                    regsub {^.*[/.]} $ff_bel {} ff_lane
                    set correct_lane [expr {$ff_lane eq [lindex {AFF BFF CFF DFF} $lane]}]
                    puts $handle [join [list $edge $index $location $ff_location $ff_bel \
                        $colocated $correct_lane] "\t"]
                    if {!$colocated || !$correct_lane} {
                        incr failures
                        if {$failures<=24} { puts "WARNING: $edge tap $index carry=$location FF=$ff_location/$ff_bel" }
                    }
                    if {$ff_location eq ""} { incr unplaced }
                }
            }
        }
    } result options]
    close $handle
    puts "Sampler layout audit: $failures mismatches, $unplaced unplaced cells. Report: $directory/placement.tsv"
    if {$code} { return -options $options $result }
    if {$unplaced>0} { error "Open a placed/routed design, not an unplaced synthesized netlist." }
    if {$failures>0} { error "Sampler placement failed: review placement.tsv before accepting fine calibration." }
    puts "Both sampler chains have consecutive carries and correctly colocated sampling FFs. This does not establish tap timing order or calibration accuracy."
}
tdc_audit_width_sampler_layout
