# Run manually in the external Vivado 2020.1 GUI with the existing project open.
# Refreshes project-local sources, archives old build evidence, rebuilds, and
# writes V18 only after setup/hold timing pass. Does not program a board.
set v18_project [current_project -quiet]
if {$v18_project eq ""} { error "Open the existing Red Pitaya project first." }
set v18_resume [expr {[info exists ::v18_resume_routed] && $::v18_resume_routed}]
set v18_scripts [file dirname [file normalize [info script]]]
set v18_repo [file normalize [file join $v18_scripts ../../..]]
set v18_rtl [file join $v18_repo prj/v0.94/rtl/tdc_registers.sv]
set v18_h [open $v18_rtl r]
set v18_text [read $v18_h]
close $v18_h
if {![string match {*5444_4312*} $v18_text]} { error "This source tree is not V18." }
set v18_synth [get_runs -quiet synth_1]
set v18_impl [get_runs -quiet impl_1]
if {[llength $v18_synth]!=1 || [llength $v18_impl]!=1} {
  error "Expected existing synth_1 and impl_1 runs."
}
foreach v18_run [list $v18_synth $v18_impl] {
  if {[string match -nocase {*running*} [get_property STATUS $v18_run]]} {
    error "A run is active; wait for it to finish before the V18 build."
  }
}
set v18_project_dir [file normalize [get_property DIRECTORY $v18_project]]
set v18_stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set v18_archive [file join $v18_project_dir tdc_build_archives $v18_stamp]
file mkdir $v18_archive
set v18_old_run [get_property DIRECTORY $v18_impl]
foreach v18_pattern {*.bit *.bin *.rpt *.dcp *.ltx} {
  foreach v18_old [glob -nocomplain -directory $v18_old_run $v18_pattern] {
    file copy -force $v18_old $v18_archive
  }
}
puts "Previous implementation evidence archived at $v18_archive"
if {!$v18_resume} {
source [file join $v18_scripts refresh_custom_sources.tcl]
reset_run $v18_synth
# Placement/physical optimization can improve the remaining short failing
# routes. Choose only strategies actually supplied by the installed Vivado.
foreach v18_strategy {Performance_ExplorePostRoutePhysOpt Performance_Explore} {
  if {![catch {set_property STRATEGY $v18_strategy $v18_impl} v18_strategy_message]} {
    puts "V18 implementation strategy: $v18_strategy"
    break
  }
}
launch_runs $v18_synth -jobs 4
wait_on_run $v18_synth
if {[get_property PROGRESS $v18_synth] ne "100%"} { error "V18 synthesis failed; inspect its log." }
launch_runs $v18_impl -to_step route_design -jobs 4
wait_on_run $v18_impl
} else {
  puts "Resuming the existing V18 route; sources and runs will not be reset."
}
# STATUS can name the NEXT pending step, for example
# 'Not started phys_opt_design (Post-Route)', after a successful route.
# Check the run's completion evidence instead of assuming one status string.
set v18_run_dir [get_property DIRECTORY $v18_impl]
if {![file exists [file join $v18_run_dir .route_design.end.rst]] ||
    [file exists [file join $v18_run_dir .route_design.error.rst]] ||
    ![file exists [file join $v18_run_dir red_pitaya_top_routed.dcp]] ||
    [regexp -nocase {error|failed|running|queued} [get_property STATUS $v18_impl]]} {
  error "V18 route did not complete: [get_property STATUS $v18_impl]"
}
# Complete the strategy's optional post-route optimization before measuring
# timing, so bitstream continuation cannot change the design after this gate.
if {[lsearch -exact [list_property $v18_impl] STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED]>=0 &&
    [get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $v18_impl]} {
  if {![regexp {phys_opt_design.*Complete|Not started write_bitstream|write_bitstream Complete} [get_property STATUS $v18_impl]]} {
  # Advance exactly one step from the completed route. This handles Vivado's
  # displayed 'phys_opt_design (Post-Route)' name without a version-specific
  # -to_step alias, and does not advance to write_bitstream.
  launch_runs $v18_impl -next_step -jobs 4
  wait_on_run $v18_impl
  if {![regexp {phys_opt_design.*Complete|Not started write_bitstream|write_bitstream Complete} [get_property STATUS $v18_impl]]} {
    error "V18 post-route optimization did not complete: [get_property STATUS $v18_impl]"
  }
  }
}
open_run $v18_impl
source [file join $v18_scripts check_custom_constraints.tcl]
set v18_reports [file join $v18_project_dir tdc_v18_reports $v18_stamp]
file mkdir $v18_reports
report_timing_summary -max_paths 50 -file [file join $v18_reports timing_summary_routed.rpt] -warn_on_violation
set v18_oddr_inputs [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_pulse_gen/i_oddr}] -filter {REF_PIN_NAME == D1 || REF_PIN_NAME == D2}]
if {[llength $v18_oddr_inputs]!=2} { error "Expected both pulse ODDR data pins." }
report_timing -to $v18_oddr_inputs -delay_type min_max -max_paths 10 -file [file join $v18_reports pulse_oddr_timing.rpt]
report_utilization -file [file join $v18_reports utilization_routed.rpt]
report_drc -file [file join $v18_reports drc_routed.rpt]
report_cdc -file [file join $v18_reports cdc_routed.rpt]
report_bus_skew -warn_on_violation -file [file join $v18_reports bus_skew_routed.rpt]
write_checkpoint -force [file join $v18_reports routed.dcp]
set v18_setup [get_timing_paths -quiet -delay_type max -max_paths 1]
set v18_hold [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $v18_setup]!=1 || [llength $v18_hold]!=1} { error "Unable to verify timing; inspect V18 reports." }
set v18_wns [get_property SLACK $v18_setup]
set v18_whs [get_property SLACK $v18_hold]
puts "V18 WNS=$v18_wns ns, WHS=$v18_whs ns; reports: $v18_reports"
if {$v18_wns<0 || $v18_whs<0} {
  error "V18 timing is not closed; reports/checkpoint saved, bitstream generation stopped."
}
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
# Keep the established board-image workflow and bootgen BIF unchanged.
set v18_bitstream [file join [get_property DIRECTORY $v18_impl] red_pitaya_top.bit]
write_bitstream -force -bin_file $v18_bitstream
puts "V18 bitstream: $v18_bitstream (binary companion in the same directory)."
puts "Reports/checkpoint: $v18_reports. Use the usual red_pitaya_top.bif/bootgen commands. No board was programmed."
