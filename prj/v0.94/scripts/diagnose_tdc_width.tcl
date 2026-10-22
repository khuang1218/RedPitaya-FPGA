# Source after opening the routed implementation that produced the tested bitstream.
# Read-only design inspection: no source, constraint, placement or run changes.
# Optional: set tdc_diagnostic_dir {C:/path/to/report/directory} before sourcing.
set tdc_diag_design [current_design -quiet]
if {[llength $tdc_diag_design] != 1} {
  error "Open the routed implementation before sourcing diagnose_tdc_width.tcl."
}
if {![info exists tdc_diagnostic_dir]} {
  set tdc_diagnostic_dir [file join [get_property DIRECTORY [current_project]] tdc_width_diagnostics]
}
set tdc_diagnostic_dir [file normalize $tdc_diagnostic_dir]
file mkdir $tdc_diagnostic_dir

proc tdc_diag_report {name args} {
  global tdc_diagnostic_dir
  # Reject empty endpoint collections rather than silently reporting unrelated paths.
  foreach option {-from -to} {
    set index [lsearch -exact $args $option]
    if {$index >= 0 && [llength [lindex $args [expr {$index+1}]]] == 0} {
      puts "SKIPPED $name: empty $option collection; inspect collections.txt."
      return
    }
  }
  report_timing -delay_type max -max_paths 40 -nworst 3 \
    -file [file join $tdc_diagnostic_dir $name.rpt] {*}$args
}

set tdc_diag_taps [get_cells -quiet -hierarchical -regexp {.*i_tdc/i_width/i_carry/gen_tap.*i_tap_ff$}]
set tdc_diag_carries [get_cells -quiet -hierarchical -filter {NAME =~ *i_tdc/i_width/i_carry/* && REF_NAME == CARRY4}]
set tdc_diag_fall_taps [get_cells -quiet -hierarchical -regexp {.*i_tdc/i_width/i_fall_carry/gen_tap.*i_tap_ff$}]
set tdc_diag_fall_carries [get_cells -quiet -hierarchical -filter {NAME =~ *i_tdc/i_width/i_fall_carry/* && REF_NAME == CARRY4}]
set tdc_diag_rise_ram [get_cells -quiet -hierarchical -filter {NAME =~ *i_tdc/i_width/rise_memory* && IS_PRIMITIVE == 1}]
set tdc_diag_fall_ram [get_cells -quiet -hierarchical -filter {NAME =~ *i_tdc/i_width/fall_memory* && IS_PRIMITIVE == 1}]
set tdc_diag_meta_ram [get_cells -quiet -hierarchical -filter {NAME =~ *i_tdc/i_width/meta_memory* && IS_PRIMITIVE == 1}]
set tdc_diag_record_ram [get_cells -quiet -hierarchical -filter {NAME =~ *i_tdc/i_width/*record_memory* && REF_NAME =~ RAMB*}]
set tdc_diag_record_write [get_cells -quiet -hierarchical -regexp {.*i_tdc/i_width/(gen_record_bank.*record_write_(data|addr|en)_local|record_write_(data|addr|en))_reg.*}]
set tdc_diag_record_read [get_cells -quiet -hierarchical -regexp {.*i_tdc/i_width/.*(record_bus_q|record_group_q|bank_q|record_read_addr_local|read_scale_base|read_scale_sub|read_coarse_ps|read_fine_delta(_s1)?|read_width_valid(_s1)?|read_width_ps|sys_rdata_o)_reg.*}]
set tdc_diag_capture_pipe [get_cells -quiet -hierarchical -regexp {.*i_tdc/i_width/((fall_)?raw_pipe_[012]|(rise|fall|meta)_en_pipe|rise_addr_pipe_[01]|slot_pipe_[01]|meta_pipe_[01])_reg.*}]
set tdc_diag_encoder [get_cells -quiet -hierarchical -filter {(NAME =~ *i_tdc/i_width/i_rise_encoder/* || NAME =~ *i_tdc/i_width/i_fall_encoder/* || NAME =~ *i_tdc/i_width/i_encoder/*) && IS_PRIMITIVE == 1}]
set tdc_diag_width [get_cells -quiet -hierarchical -filter {NAME =~ *i_tdc/i_width/* && IS_PRIMITIVE == 1}]
set tdc_diag_timestamps [get_cells -quiet -hierarchical -regexp {.*i_tdc/i_width/(ticks|rise_tick|fall_tick|watchdog|tick_carry(8|16|24)|watchdog_carry(8|16|24))_reg.*}]
set tdc_diag_arithmetic [get_cells -quiet -hierarchical -regexp {.*i_tdc/i_width/(coarse_low|coarse_ticks|coarse_base|coarse_sub|coarse_ps|(rise|fall)_lut_(q|local)|fine_delta(_low)?|fine_width|fine_in_range|coarse_in_range)_reg.*}]
set tdc_diag_sdf [get_cells -quiet -hierarchical -filter {NAME =~ *i_butterfly_static_sdf/* && IS_PRIMITIVE == 1}]
set tdc_diag_legacy [get_cells -quiet -hierarchical -regexp {.*i_tdc/(product(00|01|10|11|_sum_a|_sum_b)|fine_product_(lo|hi)|approximate_fine_product|coarse_time_product|selected_fine_ps|total_low|calculated_total_ps|last_total_ps)_reg.*}]
set tdc_diag_lut [get_cells -quiet -hierarchical -filter {(NAME =~ *i_tdc/i_width/rise_lut* || NAME =~ *i_tdc/i_width/fall_lut*) && IS_PRIMITIVE == 1}]
set tdc_diag_response [get_cells -quiet -hierarchical -regexp {.*reg_response_reg.*}]
set tdc_diag_control [get_cells -quiet -hierarchical -regexp {.*i_tdc/i_width/(lut_written|lut_group_ready|lut_ready|drain_ready|watchdog_match|staging_used|timeout_match_active|timeout_immediate)_reg.*}]
set tdc_diag_histogram [get_cells -quiet -hierarchical -filter {NAME =~ *i_tdc/i_calibration/histogram* && IS_PRIMITIVE == 1}]

set tdc_diag_handle [open [file join $tdc_diagnostic_dir collections.txt] w]
puts $tdc_diag_handle "Design: $tdc_diag_design"
puts $tdc_diag_handle "PART: [get_property PART [current_project]]"
puts $tdc_diag_handle "Tap FFs: [llength $tdc_diag_taps] (default build: 512)"
puts $tdc_diag_handle "CARRY4: [llength $tdc_diag_carries] (default build: 128)"
puts $tdc_diag_handle "Falling-polarity tap FFs: [llength $tdc_diag_fall_taps] (v9 default: 512)"
puts $tdc_diag_handle "Falling-polarity CARRY4: [llength $tdc_diag_fall_carries] (v9 default: 128)"
foreach tdc_diag_pair [list \
  [list rise_RAM $tdc_diag_rise_ram] [list fall_RAM $tdc_diag_fall_ram] \
  [list metadata_RAM $tdc_diag_meta_ram] [list result_RAM $tdc_diag_record_ram] \
  [list result_write_registers $tdc_diag_record_write] [list result_read_registers $tdc_diag_record_read] \
  [list capture_pipeline $tdc_diag_capture_pipe] \
  [list timestamp_registers $tdc_diag_timestamps] [list width_arithmetic $tdc_diag_arithmetic] \
  [list butterfly_SDF $tdc_diag_sdf] \
  [list legacy_arithmetic $tdc_diag_legacy] [list calibration_RAM $tdc_diag_lut] \
  [list bus_response $tdc_diag_response] \
  [list width_control $tdc_diag_control] \
  [list encoder $tdc_diag_encoder]] {
  lassign $tdc_diag_pair tdc_diag_label tdc_diag_cells
  puts $tdc_diag_handle "\n$tdc_diag_label: [llength $tdc_diag_cells]"
  foreach tdc_diag_cell $tdc_diag_cells {
    puts $tdc_diag_handle "[get_property REF_NAME $tdc_diag_cell] $tdc_diag_cell"
  }
}
set tdc_diag_all_taps [concat $tdc_diag_taps $tdc_diag_fall_taps]
set tdc_diag_all_carries [concat $tdc_diag_carries $tdc_diag_fall_carries]
set tdc_diag_clock_pins [get_pins -quiet -of_objects $tdc_diag_all_taps -filter {REF_PIN_NAME == C}]
set tdc_diag_clocks [get_clocks -quiet -of_objects $tdc_diag_clock_pins]
puts $tdc_diag_handle "\nTap sampling clocks: $tdc_diag_clocks"
foreach tdc_diag_clock $tdc_diag_clocks {
  puts $tdc_diag_handle "Clock $tdc_diag_clock period=[get_property PERIOD $tdc_diag_clock] ns waveform=[get_property WAVEFORM $tdc_diag_clock]"
}
close $tdc_diag_handle

report_timing_summary -delay_type min_max -max_paths 40 \
  -file [file join $tdc_diagnostic_dir timing_summary.rpt]
tdc_diag_report tap_to_rise_RAM -from $tdc_diag_taps -to $tdc_diag_rise_ram
tdc_diag_report tap_to_fall_RAM -from $tdc_diag_fall_taps -to $tdc_diag_fall_ram
# After capture pipelining the direct tap-to-RAM paths may legitimately be
# absent. Report both sides of the new stages rather than treating that as
# evidence of timing closure.
tdc_diag_report tap_to_capture_pipeline -from $tdc_diag_taps -to $tdc_diag_capture_pipe
tdc_diag_report falling_tap_to_capture_pipeline -from $tdc_diag_fall_taps -to $tdc_diag_capture_pipe
tdc_diag_report capture_pipeline_to_rise_RAM -from $tdc_diag_capture_pipe -to $tdc_diag_rise_ram
tdc_diag_report capture_pipeline_to_fall_RAM -from $tdc_diag_capture_pipe -to $tdc_diag_fall_ram
tdc_diag_report capture_pipeline_to_metadata_RAM -from $tdc_diag_capture_pipe -to $tdc_diag_meta_ram
tdc_diag_report result_RAM_write -from $tdc_diag_record_write -to $tdc_diag_record_ram
tdc_diag_report result_RAM_read -from $tdc_diag_record_ram -to $tdc_diag_record_read
tdc_diag_report encoder -from $tdc_diag_encoder -to $tdc_diag_encoder
tdc_diag_report width_internal -from $tdc_diag_width -to $tdc_diag_width
tdc_diag_report timestamp_and_watchdog -from $tdc_diag_timestamps -to $tdc_diag_timestamps
tdc_diag_report timestamp_to_metadata -from $tdc_diag_timestamps -to $tdc_diag_meta_ram
tdc_diag_report timestamp_to_metadata_pipeline -from $tdc_diag_timestamps -to $tdc_diag_capture_pipe
tdc_diag_report width_arithmetic -from $tdc_diag_width -to $tdc_diag_arithmetic
tdc_diag_report butterfly_SDF -from $tdc_diag_sdf -to $tdc_diag_sdf
tdc_diag_report legacy_arithmetic_inputs -to $tdc_diag_legacy
tdc_diag_report calibration_RAM_outputs -from $tdc_diag_lut
tdc_diag_report legacy_histogram -from $tdc_diag_histogram -to $tdc_diag_histogram
tdc_diag_report bus_response_inputs -to $tdc_diag_response
tdc_diag_report bus_response_outputs -from $tdc_diag_response
tdc_diag_report width_control_inputs -to $tdc_diag_control
tdc_diag_report width_control_outputs -from $tdc_diag_control
report_utilization -hierarchical -file [file join $tdc_diagnostic_dir utilization.rpt]
report_bus_skew -file [file join $tdc_diagnostic_dir bus_skew.rpt]
report_clock_interaction -file [file join $tdc_diagnostic_dir clock_interaction.rpt]
report_cdc -file [file join $tdc_diagnostic_dir cdc.rpt]

set tdc_diag_handle [open [file join $tdc_diagnostic_dir tap_placement.txt] w]
puts $tdc_diag_handle "Tap FF / LOC / BEL / CLOCK_REGION"
foreach tdc_diag_cell [lsort -dictionary $tdc_diag_all_taps] {
  set tdc_diag_site [get_sites -quiet -of_objects [list $tdc_diag_cell]]
  set tdc_diag_region {}
  if {[llength $tdc_diag_site]} {
    set tdc_diag_region [get_clock_regions -quiet -of_objects $tdc_diag_site]
  }
  puts $tdc_diag_handle "$tdc_diag_cell [get_property LOC [list $tdc_diag_cell]] [get_property BEL [list $tdc_diag_cell]] $tdc_diag_region"
}
puts $tdc_diag_handle "\nCARRY4 / LOC / BEL"
foreach tdc_diag_cell [lsort -dictionary $tdc_diag_all_carries] {
  puts $tdc_diag_handle "$tdc_diag_cell [get_property LOC [list $tdc_diag_cell]] [get_property BEL [list $tdc_diag_cell]]"
}
close $tdc_diag_handle
puts "TDC width diagnostics written to $tdc_diagnostic_dir. Check negative slack, empty collections and the clock period."
puts "These reports inspect the open design; verify it matches the bitstream used for the saved measurements."

set tdc_diag_frame_delay [get_cells -quiet -hier -filter {NAME =~ *i_tdc/i_width/i_frame_delay/* && IS_PRIMITIVE == 1}]
tdc_diag_report frame_delay -from $tdc_diag_frame_delay
