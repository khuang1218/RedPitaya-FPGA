# Source in the existing Vivado GUI project. Imports project-local copies;
# does not start synthesis, implementation, or programming.
# Example: source C:/path/to/RedPitaya-FPGA/prj/v0.94/scripts/refresh_custom_sources.tcl
set custom_project [current_project -quiet]
if {![info exists custom_enable_bnet]} { set custom_enable_bnet 0 }
if {$custom_project eq ""} { error "Open the existing Vivado project before sourcing this script." }
set custom_repo [file normalize [file join [file dirname [info script]] ../../..]]
set custom_sources [get_filesets -quiet sources_1]
set custom_constraints [get_filesets -quiet constrs_1]
if {[llength $custom_sources] != 1 || [llength $custom_constraints] != 1} {
  error "The open project must have sources_1 and constrs_1 filesets."
}
set custom_copy_root [file normalize [file join [get_property DIRECTORY $custom_project] \
  "[get_property NAME $custom_project].srcs"]]

set custom_module_names {
  pulse_gen.sv bnet_axi_reader_ch.sv butterfly_network_static_sdf.sv
  tdc_top.sv tdc_registers.sv tdc_pulse_width.sv tdc_frame_delay.sv
}
# Require the changed launch/register/capture modules explicitly. Refresh the
# full TDC dependency set, including the internal and MMCM stimulus sources, to
# prevent stale imported encoder/carry/FIFO copies from surviving a refresh.
foreach custom_path [lsort [glob -nocomplain [file join $custom_repo prj/v0.94/rtl/tdc_*.sv]]] {
  lappend custom_module_names [file tail $custom_path]
}
set custom_module_names [lsort -unique $custom_module_names]
set custom_top_name red_pitaya_top_LED7_mod.sv
set custom_xdc_names {tdc_Z20_G2.xdc tdc_width_sampler_layout.xdc pulse_gen_Z20_G2.xdc bnet_reader_Z20_G2.xdc}
set custom_shared_sources {rtl/sys_bus_cdc.sv rtl/classic/red_pitaya_daisy.v rtl/classic/red_pitaya_asg_ch.sv rtl/classic/rp_decim.v}
# Check the whole input list before changing the project's file membership.
foreach custom_name [concat $custom_module_names [list $custom_top_name]] {
  set custom_path [file join $custom_repo prj/v0.94/rtl $custom_name]
  if {![file isfile $custom_path]} { error "Missing $custom_path" }
}
foreach custom_relative $custom_shared_sources {
  if {![file isfile [file join $custom_repo $custom_relative]]} { error "Missing $custom_relative" }
}
foreach custom_name [concat $custom_xdc_names {red_pitaya_G2.xdc}] {
  set custom_path [file join $custom_repo prj/v0.94/sdc $custom_name]
  if {![file isfile $custom_path]} { error "Missing $custom_path" }
}

proc custom_import_copy {fileset source_path} {
  global custom_copy_root
  set source_path [file normalize $source_path]
  set expected_copy [file join $custom_copy_root [get_property NAME $fileset] imports [file tail $source_path]]
  if {[string equal -nocase $source_path [file normalize $expected_copy]]} {
    error "Repository source and project copy must be separate files: $source_path"
  }
  foreach old_file [get_files -quiet -of_objects $fileset] {
    if {[file tail $old_file] eq [file tail $source_path]} {
      # Remove membership only; remove_files does not delete files on disk.
      remove_files [list $old_file]
    }
  }
  # -flat puts the copy directly in <project>.srcs/<fileset>/imports/.
  # -force refreshes that copy on subsequent runs, even when it already exists.
  set local_file [import_files -force -norecurse -flat -fileset $fileset $source_path]
  if {[llength $local_file] != 1} { error "Import failed for $source_path" }
  set local_path [file normalize [get_property NAME $local_file]]
  if {![string equal -nocase $local_path [file normalize $expected_copy]] ||
      ![file isfile $local_path]} {
    error "Expected a project-local copy at $expected_copy, but Vivado returned $local_path"
  }
  # Check bytes, not timestamps: a successful refresh must contain this RTL.
  set source_handle [open $source_path rb]
  set source_data [read $source_handle]
  close $source_handle
  set local_handle [open $local_path rb]
  set local_data [read $local_handle]
  close $local_handle
  if {$source_data ne $local_data} { error "Imported copy is stale or differs from $source_path: $local_path" }
  puts "Verified project copy: $local_path"
  return $local_file
}

foreach custom_name $custom_module_names {
  set custom_local [custom_import_copy $custom_sources [file join $custom_repo prj/v0.94/rtl $custom_name]]
  set_property file_type SystemVerilog $custom_local
  set_property used_in_synthesis true $custom_local
  set_property used_in_implementation true $custom_local
  set_property used_in_simulation true $custom_local
}
# Shared CDC, daisy-selector and ASG timing repairs need project-owned copies.
foreach custom_relative $custom_shared_sources {
  set custom_local [custom_import_copy $custom_sources [file join $custom_repo $custom_relative]]
  set_property file_type [expr {[file extension $custom_relative] eq ".sv" ? "SystemVerilog" : "Verilog"}] $custom_local
  set_property used_in_synthesis true $custom_local
  set_property used_in_implementation true $custom_local
  set_property used_in_simulation true $custom_local
}
# Select the merged top, including the confirmed internal LVDS termination.
# Retain competing top files as disabled copies so the change is reversible.
foreach custom_old [get_files -quiet -of_objects $custom_sources] {
  if {[string match red_pitaya_top*.sv [file tail $custom_old]]} {
    set_property used_in_synthesis false [list $custom_old]
    set_property used_in_implementation false [list $custom_old]
    set_property used_in_simulation false [list $custom_old]
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
  if {$custom_name eq "bnet_reader_Z20_G2.xdc" && !$custom_enable_bnet} {
    set_property used_in_implementation false $custom_local
  }
}
# Refresh the existing Gen2 board constraint copy as well (single E3 clock).
custom_import_copy $custom_constraints [file join $custom_repo prj/v0.94/sdc/red_pitaya_G2.xdc]

set custom_defs [get_property verilog_define $custom_sources]
set custom_clean_defs {}
foreach custom_def $custom_defs {
  if {![regexp {^(SCOPE_ONLY|DISABLE_BNET)(=|$)} $custom_def]} { lappend custom_clean_defs $custom_def }
}
foreach custom_def {Z20_G2 Z20_xx} {
  if {[lsearch -exact $custom_clean_defs $custom_def] < 0} { lappend custom_clean_defs $custom_def }
}
set_property verilog_define $custom_clean_defs $custom_sources
if {!$custom_enable_bnet} {
  lappend custom_clean_defs DISABLE_BNET
  set_property verilog_define $custom_clean_defs $custom_sources
}
puts "BNET enabled: $custom_enable_bnet (set custom_enable_bnet 1 before sourcing to restore it)"
puts "TDC v14 source: passing-v12 capture with fixed frame offset. ID 0x5444430e; deploy matching API/SCPI for TDC:WIDTH:OFFSET and recalibrate fresh LUTs. New routed WNS remains to be measured."
update_compile_order -fileset sources_1
puts "Custom sources copied and verified under $custom_copy_root. Rerun this script after workspace edits to refresh the copies. Reset synthesis/implementation before rebuilding."
