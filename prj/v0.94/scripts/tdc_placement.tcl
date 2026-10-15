###############################################################################
# Placement/check helpers for the 512-tap CARRY4 TDC.
#
# Usage after opening the synthesized design:
#   source prj/v0.94/scripts/tdc_placement.tcl
#   tdc_place_chain <SLICE_X number> <first SLICE_Y number>
#   tdc_write_placement_xdc <output.xdc> <SLICE_X number> <first SLICE_Y number>
# Optional final hierarchy argument selects the new width path:
#   tdc_place_chain <X> <Y> i_tdc/i_width/i_carry
#   tdc_write_placement_xdc <width.xdc> <X> <Y> i_tdc/i_width/i_carry
# Choose separate legal locations for legacy and width chains.
#
# Example syntax only (the coordinates are NOT a recommendation):
#   tdc_place_chain 42 10
###############################################################################

proc tdc_get_carries {{hierarchy i_tdc/i_carry}} {
  return [lsort -dictionary [get_cells -quiet -hierarchical -filter \
    "REF_NAME == CARRY4 && NAME =~ *$hierarchy/*"]]
}

proc tdc_get_tap_ffs {{hierarchy i_tdc/i_carry}} {
  return [lsort -dictionary [get_cells -quiet -hierarchical -filter \
    "REF_NAME == FDRE && NAME =~ *$hierarchy/gen_tap*i_tap_ff"]]
}

proc tdc_place_chain {slice_x first_slice_y {hierarchy i_tdc/i_carry}} {
  set carries [tdc_get_carries $hierarchy]
  set tap_ffs [tdc_get_tap_ffs $hierarchy]
  set carry_count [llength $carries]
  set tap_count [llength $tap_ffs]

  if {$carry_count == 0} {
    error "No TDC CARRY4 cells found. Open the synthesized design and check hierarchy preservation."
  }
  if {$tap_count != 4 * $carry_count} {
    error "Expected four TDC FDRE cells per CARRY4; found $tap_count FFs and $carry_count carries."
  }

  set bels {AFF BFF CFF DFF}
  for {set stage 0} {$stage < $carry_count} {incr stage} {
    set site_name "SLICE_X${slice_x}Y[expr {$first_slice_y + $stage}]"
    set site [get_sites -quiet $site_name]
    if {[llength $site] != 1} {
      error "Required site $site_name does not exist on the selected part."
    }

    set carry_cell [lindex $carries $stage]
    set_property LOC $site_name $carry_cell

    for {set lane 0} {$lane < 4} {incr lane} {
      set tap_cell [lindex $tap_ffs [expr {$stage * 4 + $lane}]]
      set_property BEL [lindex $bels $lane] $tap_cell
      set_property LOC $site_name $tap_cell
    }
  }

  puts "Placed $carry_count TDC CARRY4 cells and $tap_count tap FFs in SLICE_X${slice_x}, starting at Y${first_slice_y}."
}

proc tdc_write_placement_xdc {output_file slice_x first_slice_y {hierarchy i_tdc/i_carry}} {
  set carries [tdc_get_carries $hierarchy]
  set tap_ffs [tdc_get_tap_ffs $hierarchy]
  set carry_count [llength $carries]
  set tap_count [llength $tap_ffs]

  if {$carry_count == 0 || $tap_count != 4 * $carry_count} {
    error "Open the synthesized design first; the expected TDC primitive hierarchy was not found."
  }

  set handle [open $output_file w]
  puts $handle "# Generated from the synthesized LED7_mod TDC hierarchy."
  puts $handle "# Keep this file with the calibration produced for this bitstream."
  set bels {AFF BFF CFF DFF}
  for {set stage 0} {$stage < $carry_count} {incr stage} {
    set site_name "SLICE_X${slice_x}Y[expr {$first_slice_y + $stage}]"
    if {[llength [get_sites -quiet $site_name]] != 1} {
      close $handle
      error "Required site $site_name does not exist on the selected part."
    }
    set carry_cell [lindex $carries $stage]
    puts $handle "set_property LOC $site_name \[get_cells {$carry_cell}\]"
    for {set lane 0} {$lane < 4} {incr lane} {
      set tap_cell [lindex $tap_ffs [expr {$stage * 4 + $lane}]]
      set bel [lindex $bels $lane]
      puts $handle "set_property BEL $bel \[get_cells {$tap_cell}\]"
      puts $handle "set_property LOC $site_name \[get_cells {$tap_cell}\]"
    }
  }
  close $handle
  puts "Wrote TDC placement constraints to $output_file"
  puts "Add the file to constrs_1 with USED_IN_SYNTHESIS=false and USED_IN_IMPLEMENTATION=true."
}

proc tdc_report_placement {{hierarchy i_tdc/i_carry}} {
  set carries [tdc_get_carries $hierarchy]
  set tap_ffs [tdc_get_tap_ffs $hierarchy]
  puts "TDC CARRY4 count: [llength $carries]"
  puts "TDC tap FDRE count: [llength $tap_ffs]"
  foreach cell $carries {
    puts "[get_property LOC $cell] $cell"
  }
}
