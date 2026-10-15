# Source in the existing Vivado GUI project. Imports project-local copies;
# does not start synthesis, implementation, or programming.
set custom_repo [file normalize [file join [file dirname [info script]] ../../..]]
set custom_sources [get_filesets sources_1]
set custom_constraints [get_filesets constrs_1]

set custom_module_names {pulse_gen.sv bnet_axi_reader_ch.sv}
# Refresh the full TDC dependency set, including the new capture module, to
# prevent stale imported encoder/carry/FIFO copies from surviving a refresh.
foreach custom_path [lsort [glob -nocomplain [file join $custom_repo prj/v0.94/rtl/tdc_*.sv]]] {
  lappend custom_module_names [file tail $custom_path]
}
set custom_top_name red_pitaya_top_LED7_mod.sv
set custom_xdc_names {tdc_Z20_G2.xdc pulse_gen_Z20_G2.xdc bnet_reader_Z20_G2.xdc}
# Check the whole input list before changing the project's file membership.
foreach custom_name [concat $custom_module_names [list $custom_top_name]] {
  set custom_path [file join $custom_repo prj/v0.94/rtl $custom_name]
  if {![file isfile $custom_path]} { error "Missing $custom_path" }
}
foreach custom_name [concat $custom_xdc_names {red_pitaya_G2.xdc}] {
  set custom_path [file join $custom_repo prj/v0.94/sdc $custom_name]
  if {![file isfile $custom_path]} { error "Missing $custom_path" }
}

proc custom_import_copy {fileset source_path} {
  foreach old_file [get_files -quiet -of_objects $fileset] {
    if {[file tail $old_file] eq [file tail $source_path]} {
      # Remove membership only; remove_files does not delete files on disk.
      remove_files $old_file
    }
  }
  # -flat puts the copy directly in <project>.srcs/<fileset>/imports/.
  # -force refreshes that copy on subsequent runs, even when it already exists.
  set local_file [import_files -force -norecurse -flat -fileset $fileset $source_path]
  if {[llength $local_file] != 1} { error "Import failed for $source_path" }
  puts "Project copy: $local_file"
  return $local_file
}

foreach custom_name $custom_module_names {
  custom_import_copy $custom_sources [file join $custom_repo prj/v0.94/rtl $custom_name]
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
set custom_top [custom_import_copy $custom_sources [file join $custom_repo prj/v0.94/rtl $custom_top_name]]
set_property used_in_synthesis true $custom_top
set_property used_in_implementation true $custom_top
set_property used_in_simulation true $custom_top
set_property top red_pitaya_top $custom_sources
foreach custom_name $custom_xdc_names {
  set custom_local [custom_import_copy $custom_constraints [file join $custom_repo prj/v0.94/sdc $custom_name]]
  set_property used_in_synthesis false $custom_local
  set_property used_in_implementation true $custom_local
  set_property processing_order LATE $custom_local
}
# Refresh the existing Gen2 board constraint copy as well (single E3 clock).
custom_import_copy $custom_constraints [file join $custom_repo prj/v0.94/sdc/red_pitaya_G2.xdc]

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
puts "Custom sources copied from $custom_repo into the project. Rerun this script after workspace edits to refresh the copies. Reset synthesis/implementation before rebuilding."
