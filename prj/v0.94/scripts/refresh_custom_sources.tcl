# Source in the existing Vivado GUI project. Updates references/properties;
# does not start synthesis, implementation, or programming.
set custom_repo [file normalize [file join [file dirname [info script]] ../../..]]
set custom_sources [get_filesets sources_1]
set custom_constraints [get_filesets constrs_1]

foreach custom_name {pulse_gen.sv bnet_axi_reader_ch.sv tdc_top.sv tdc_registers.sv tdc_mmcm_stimulus.sv tdc_lvds_io.sv} {
  set custom_path [file join $custom_repo prj/v0.94/rtl $custom_name]
  if {![file exists $custom_path]} { error "Missing $custom_path" }
  foreach custom_old [get_files -quiet -of_objects $custom_sources] {
    if {[file tail $custom_old] eq $custom_name} { remove_files $custom_old }
  }
  add_files -norecurse -fileset sources_1 $custom_path
}
# Select the merged top, including the confirmed internal LVDS termination.
# Retain competing top files as disabled copies so the change is reversible.
foreach custom_old [get_files -quiet -of_objects $custom_sources] {
  if {[string match red_pitaya_top*.sv [file tail $custom_old]]} {
    set_property used_in_synthesis false $custom_old
    set_property used_in_implementation false $custom_old
    set_property used_in_simulation false $custom_old
  }
}
set custom_top [file join $custom_repo prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv]
if {[llength [get_files -quiet $custom_top]] == 0} {
  add_files -norecurse -fileset sources_1 $custom_top
}
set_property used_in_synthesis true [get_files $custom_top]
set_property used_in_implementation true [get_files $custom_top]
set_property used_in_simulation true [get_files $custom_top]
set_property top red_pitaya_top $custom_sources
foreach custom_name {tdc_Z20_G2.xdc pulse_gen_Z20_G2.xdc bnet_reader_Z20_G2.xdc} {
  set custom_path [file join $custom_repo prj/v0.94/sdc $custom_name]
  if {![file exists $custom_path]} { error "Missing $custom_path" }
  foreach custom_old [get_files -quiet -of_objects $custom_constraints] {
    if {[file tail $custom_old] eq $custom_name} { remove_files $custom_old }
  }
  add_files -norecurse -fileset constrs_1 $custom_path
  set_property used_in_synthesis false [get_files $custom_path]
  set_property used_in_implementation true [get_files $custom_path]
  set_property processing_order LATE [get_files $custom_path]
}
# Refresh the existing Gen2 board constraint copy as well (single E3 clock).
foreach custom_old [get_files -quiet -of_objects $custom_constraints] {
  if {[file tail $custom_old] eq "red_pitaya_G2.xdc"} { remove_files $custom_old }
}
add_files -norecurse -fileset constrs_1 [file join $custom_repo prj/v0.94/sdc/red_pitaya_G2.xdc]

set custom_defs [get_property verilog_define $custom_sources]
set custom_clean_defs {}
foreach custom_def $custom_defs {
  if {![regexp {^SCOPE_ONLY(=|$)} $custom_def]} { lappend custom_clean_defs $custom_def }
}
foreach custom_def {Z20_G2 Z20_xx} {
  if {[lsearch -exact $custom_clean_defs $custom_def] < 0} { lappend custom_clean_defs $custom_def }
}
set_property verilog_define $custom_clean_defs $custom_sources
update_compile_order -fileset sources_1
puts "Custom sources refreshed from $custom_repo. Reset synthesis/implementation before rebuilding."
