# Finish the completed v19 implementation. No source refresh, run reset,
# synthesis, placement, routing, optimization or board programming is launched.
# Also sourced by the full build helper to share every bitstream acceptance gate.
set v19_finish_project [current_project -quiet]
if {[llength $v19_finish_project]!=1} {error "Open the existing v19 project first."}
set v19_finish_scripts [file dirname [file normalize [info script]]]
set v19_finish_impl [get_runs -quiet impl_1]
if {[llength $v19_finish_impl]!=1} {error "Expected the existing impl_1 run."}
set v19_finish_status [get_property STATUS $v19_finish_impl]
if {[regexp -nocase {error|failed|running|queued} $v19_finish_status]} {
  error "V19 implementation is not ready: $v19_finish_status"
}
set v19_finish_dir [get_property DIRECTORY $v19_finish_impl]
if {![file exists [file join $v19_finish_dir .route_design.end.rst]] ||
    [file exists [file join $v19_finish_dir .route_design.error.rst]] ||
    ![file exists [file join $v19_finish_dir red_pitaya_top_routed.dcp]]} {
  error "No completed routed implementation. Run build_tdc_v19.tcl first."
}
if {[lsearch -exact [list_property $v19_finish_impl] STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED]>=0 &&
    [get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $v19_finish_impl] &&
    ![regexp {phys_opt_design.*Complete|Not started write_bitstream|write_bitstream Complete} $v19_finish_status]} {
  error "Configured post-route optimization is incomplete: $v19_finish_status"
}
# Always reopen the completed run, not an unrelated or edited in-memory design.
if {[llength [current_design -quiet]]>0} {close_design}
open_run $v19_finish_impl
set v19_finish_reports [file join [get_property DIRECTORY $v19_finish_project] \
  tdc_v19_reports finish_[clock format [clock seconds] -format %Y%m%d_%H%M%S]]
file mkdir $v19_finish_reports
report_timing_summary -max_paths 100 -file [file join $v19_finish_reports timing_summary_routed.rpt] -warn_on_violation
report_drc -file [file join $v19_finish_reports drc_routed.rpt]
report_utilization -file [file join $v19_finish_reports utilization_routed.rpt]
source [file join $v19_finish_scripts check_v19_constraints.tcl]
source [file join $v19_finish_scripts audit_v19_sampler_layout.tcl]
set v19_finish_setup [get_timing_paths -quiet -delay_type max -max_paths 1]
set v19_finish_hold [get_timing_paths -quiet -delay_type min -max_paths 1]
if {[llength $v19_finish_setup]!=1 || [llength $v19_finish_hold]!=1} {
  error "Unable to verify V19 setup/hold; no bitstream generated."
}
set v19_finish_wns [get_property SLACK $v19_finish_setup]
set v19_finish_whs [get_property SLACK $v19_finish_hold]
puts "V19 WNS=$v19_finish_wns ns, WHS=$v19_finish_whs ns; reports $v19_finish_reports"
if {$v19_finish_wns<0 || $v19_finish_whs<0} {error "V19 timing failed; no bitstream generated."}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]>0} {
  error "V19 DRC errors remain; no bitstream generated."
}
if {$v19_finish_wns<0.100} {puts "NOTE: V19 setup margin is below 100 ps; retain reports with this image."}
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set v19_finish_bit [file join $v19_finish_dir red_pitaya_v19.bit]
write_bitstream -force -bin_file $v19_finish_bit
puts "V19 bitstream: $v19_finish_bit (binary companion red_pitaya_v19.bin)."
puts "No board programmed. Collect new calibration for each channel before fine-mode acceptance."
