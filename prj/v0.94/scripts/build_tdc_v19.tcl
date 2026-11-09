# Run manually in the existing external Vivado 2020.1 project. No programming.
# Archives the prior implementation and writes impl_1/red_pitaya_v19.bit.
set v19_project [current_project -quiet]
if {$v19_project eq ""} {error "Open the existing Red Pitaya project first."}
set v19_scripts [file dirname [file normalize [info script]]]
set v19_repo [file normalize [file join $v19_scripts ../../..]]
set v19_project_dir [file normalize [get_property DIRECTORY $v19_project]]
set v19_synth [get_runs -quiet synth_1]
set v19_impl [get_runs -quiet impl_1]
if {[llength $v19_synth]!=1 || [llength $v19_impl]!=1} {error "Expected synth_1 and impl_1."}
foreach v19_run [list $v19_synth $v19_impl] {
  if {[regexp -nocase {running|queued} [get_property STATUS $v19_run]]} {error "A run is active; wait first."}
}
set v19_stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set v19_archive [file join $v19_project_dir tdc_build_archives $v19_stamp]
set v19_run_dir [get_property DIRECTORY $v19_impl]
file mkdir $v19_archive
set v19_xpr [file join $v19_project_dir "[get_property NAME $v19_project].xpr"]
if {[file exists $v19_xpr]} {file copy -force $v19_xpr [file join $v19_archive project_before_v19.xpr]}
foreach v19_pattern {*.bit *.bin *.rpt *.dcp *.ltx} {
  foreach v19_old [glob -nocomplain -directory $v19_run_dir $v19_pattern] {file copy -force $v19_old $v19_archive}
}
puts "Previous implementation archived: $v19_archive"
# A failed structural check leaves synth_1 open. Close that in-memory design
# before refreshing sources and resetting the runs for this full rebuild.
if {[llength [current_design -quiet]]>0} {close_design}
set custom_enable_bnet 0
source [file join $v19_scripts refresh_v19_sources.tcl]
reset_run $v19_impl
reset_run $v19_synth
set v19_strategy_found 0
foreach v19_strategy {Performance_ExplorePostRoutePhysOpt Performance_Explore} {
  if {![catch {set_property STRATEGY $v19_strategy $v19_impl}]} {set v19_strategy_found 1;break}
}
if {!$v19_strategy_found} {error "No supported performance strategy found."}
# Use supported implementation effort controls on the same clocks and paths.
# Four small 250 MHz setup failures remained in the first routed v19 attempt.
foreach {v19_property v19_directive} {
  STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt
  STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore
  STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore
  STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore
} {
  if {[lsearch -exact [list_property $v19_impl] $v19_property]>=0} {
    if {[catch {set_property $v19_property $v19_directive $v19_impl} v19_directive_error]} {
      puts "V19 kept strategy default for $v19_property: $v19_directive_error"
    } else {puts "V19 $v19_property=$v19_directive"}
  }
}
launch_runs $v19_synth -jobs 4
wait_on_run $v19_synth
if {[get_property PROGRESS $v19_synth] ne "100%"} {error "V19 synthesis failed; inspect its log."}
open_run $v19_synth
source [file join $v19_scripts check_v19_constraints.tcl]
close_design
launch_runs $v19_impl -to_step route_design -jobs 4
wait_on_run $v19_impl
if {![file exists [file join $v19_run_dir .route_design.end.rst]] ||
    [file exists [file join $v19_run_dir .route_design.error.rst]] ||
    [regexp -nocase {error|failed|running|queued} [get_property STATUS $v19_impl]]} {
  error "V19 route did not finish: [get_property STATUS $v19_impl]"
}
if {[lsearch -exact [list_property $v19_impl] STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED]>=0 &&
    [get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $v19_impl]} {
  if {![regexp {phys_opt_design.*Complete|Not started write_bitstream|write_bitstream Complete} [get_property STATUS $v19_impl]]} {
    launch_runs $v19_impl -next_step -jobs 4
    wait_on_run $v19_impl
    if {![regexp {phys_opt_design.*Complete|Not started write_bitstream|write_bitstream Complete} [get_property STATUS $v19_impl]]} {
      error "V19 post-route optimization did not complete."
    }
  }
}
open_run $v19_impl
set v19_reports [file join $v19_project_dir tdc_v19_reports $v19_stamp]
file mkdir $v19_reports
report_timing_summary -max_paths 100 -file [file join $v19_reports timing_summary_routed.rpt] -warn_on_violation
report_utilization -file [file join $v19_reports utilization_routed.rpt]
report_utilization -hierarchical -hierarchical_depth 5 -file [file join $v19_reports utilization_hierarchical.rpt]
report_drc -file [file join $v19_reports drc_routed.rpt]
report_cdc -file [file join $v19_reports cdc_routed.rpt]
report_exceptions -file [file join $v19_reports exceptions_routed.rpt]
report_bus_skew -warn_on_violation -file [file join $v19_reports bus_skew_routed.rpt]
report_io -file [file join $v19_reports io_routed.rpt]
write_checkpoint -force [file join $v19_reports routed.dcp]
source [file join $v19_scripts finish_tdc_v19.tcl]
