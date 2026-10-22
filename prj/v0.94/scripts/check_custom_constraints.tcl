# Source with a synthesized or implemented design open. Keep conditional Tcl
# here, outside managed XDC. This validates names/counts, not routed timing.
proc custom_check_count {label objects minimum {maximum -1}} {
  set count [llength $objects]
  if {$count < $minimum || ($maximum >= 0 && $count > $maximum)} {
    error "$label: found $count objects, expected $minimum..$maximum; inspect hierarchy/constraints"
  }
  puts "$label: $count"
}
custom_check_count "TDC carries" [get_cells -quiet -hier -filter {REF_NAME == CARRY4 && NAME =~ *i_tdc/i_carry/*}] 128 128
custom_check_count "TDC tap D pins" [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_carry/gen_tap*i_tap_ff/D}] 512 512
custom_check_count "Width TDC carries" [get_cells -quiet -hier -filter {REF_NAME == CARRY4 && NAME =~ *i_tdc/i_width/i_carry/*}] 128 128
custom_check_count "Width TDC tap D pins" [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_width/i_carry/gen_tap*i_tap_ff/D}] 512 512
custom_check_count "Width falling TDC carries" [get_cells -quiet -hier -filter {REF_NAME == CARRY4 && NAME =~ *i_tdc/i_width/i_fall_carry/*}] 128 128
custom_check_count "Width falling TDC tap D pins" [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_width/i_fall_carry/gen_tap*i_tap_ff/D}] 512 512
set custom_width_layout [get_files -quiet *tdc_width_sampler_layout.xdc]
custom_check_count "Width physical layout XDC" $custom_width_layout 1 1
if {![get_property USED_IN_IMPLEMENTATION $custom_width_layout] ||
    [get_property USED_IN_SYNTHESIS $custom_width_layout]} {
  error "Width sampler layout XDC must be enabled for implementation only."
}
# A large result array must infer dedicated BRAM; count after synthesis rather
# than accepting LUT/FF expansion. Actual packing/total use is report-dependent.
custom_check_count "Width result BRAM primitives" [get_cells -quiet -hier -filter {NAME =~ *i_tdc/i_width/* && REF_NAME =~ RAMB*}] 1
custom_check_count "Width calibration BRAM primitives" [get_cells -quiet -hier -filter {(NAME =~ *i_tdc/i_width/rise_lut* || NAME =~ *i_tdc/i_width/fall_lut*) && REF_NAME =~ RAMB*}] 2
custom_check_count "Width rise encoder" [get_cells -quiet -hier -filter {NAME =~ *i_tdc/i_width/i_rise_encoder/* && IS_PRIMITIVE == 1}] 1
custom_check_count "Width fall encoder" [get_cells -quiet -hier -filter {NAME =~ *i_tdc/i_width/i_fall_encoder/* && IS_PRIMITIVE == 1}] 1
custom_check_count "Width local LUT outputs" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(rise|fall)_lut_local_reg\[[0-9]+\]}] 32 32
custom_check_count "Pulse final ODDR data registers" [get_cells -quiet -hier -regexp {.*i_pulse_gen/oddr_data_reg\[[01]\]}] 2 2
custom_check_count "Width first CDC stages" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(request_sync|abort_sync|ack_sync|capture_sync|process_sync)_reg\[0\]}] 5 5
custom_check_count "Width reset synchronizer CLR pins" [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_tdc/i_width/fast_reset_pipe_reg\[[0-2]\]}] -filter {REF_PIN_NAME == CLR}] 3 3
custom_check_count "Width configuration mailbox" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(requested_count|timeout_match_cfg|timeout_immediate_cfg|lut_enabled|clear_request|frame_match_cfg|frame_zero_cfg|frame_one_cfg|frame_offset_cfg)_reg(\[[0-9]+\])?}] 1
custom_check_count "Scope local decimation configuration" [get_cells -quiet -hier -regexp {.*i_scope/.*i_dec/set_dec_local_reg\[[0-9]+\]}] 17
custom_check_count "Width registered timeout halves" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/watchdog_match_reg\[[01]\]}] 2 2
custom_check_count "Width population encoder registers" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/i_(rise|fall)_encoder/population_reg\[[0-9]+\]}] 20 20
custom_check_count "Width bounded transition decisions" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/i_(rise|fall)_encoder/transition_span_ok_reg}] 2 2
custom_check_count "Legacy histogram pipeline" [get_cells -quiet -hier -regexp {.*i_tdc/i_calibration/histogram_(read|write)_pending_reg}] 2 2
custom_check_count "Width registered completion decision" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/drain_ready_reg.*}] 1
custom_check_count "Width registered arithmetic ranges" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(fine_in_range|coarse_in_range)_reg}] 2 2
custom_check_count "Width completion metadata" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(completed_fast|flags_fast)_reg\[[0-9]+\]}] 1
foreach pattern {*i_tdc/return_sync_meta_reg/D *i_tdc/i_internal_stimulus/enable_meta_reg/D *i_tdc/i_mmcm_stimulus/toggle_meta_reg/D *i_tdc/i_mmcm_stimulus/locked_meta_reg/D} {
  custom_check_count $pattern [get_pins -quiet -hier -filter "NAME =~ $pattern"] 1 1
}
custom_check_count "Pulse first CDC stages" [get_cells -quiet -hier -regexp {.*i_pulse_gen/(request_sync|ack_sync|claim_sync|enable_sync|ready_sync|gpio_data_sync)_reg\[0\]}] 6 6
custom_check_count "Pulse reset synchronizer CLR pins" [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_pulse_gen/((bus|fast)_reset_pipe_reg\[[0-2]\]|oddr_rstn_reg)}] -filter {REF_PIN_NAME == CLR}] 7 7
custom_check_count "TDC reset synchronizer CLR pins" [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_mmcm_stimulus/test_rstn*_reg/CLR}] 2 2
custom_check_count "Pulse mailbox" [get_cells -quiet -hier -regexp {.*i_pulse_gen/mailbox_(period|high|last|prelast|enable)_reg(\[[0-9]+\])?}] 1
custom_check_count "Pulse active values" [get_cells -quiet -hier -regexp {.*i_pulse_gen/active_(period|high|last|prelast|enable)_reg(\[[0-9]+\])?}] 1
custom_check_count "Pulse registered terminal decision" [get_cells -quiet -hier -regexp {.*i_pulse_gen/phase_last_reg}] 1 1
custom_check_count "Pulse readback" [get_cells -quiet -hier -regexp {.*i_pulse_gen/readback_(period|high)_reg\[[0-9]+\]}] 1
set custom_bnet_disabled [expr {[lsearch -regexp [get_property verilog_define [get_filesets sources_1]] {^DISABLE_BNET(=|$)}]>=0}]
if {$custom_bnet_disabled} {
  custom_check_count "BNET excluded from hardware" [get_cells -quiet -hier -regexp {.*(i_bnet_.*|i_butterfly_.*)}] 0 0
} else {
custom_check_count "BNET first CDC stages" [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(start_toggle_axi_meta|soft_reset_toggle_axi_meta|debug_request_meta|debug_ack_meta)_reg}] 8 8
custom_check_count "BNET debug mailbox" [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/debug_mailbox_axi_reg\[[0-9]+\]}] 1
custom_check_count "BNET debug snapshot" [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(debug0_snapshot|debug1_o)_reg\[[0-9]+\]}] 1
custom_check_count "BNET descriptor registers" [get_cells -quiet -hier -regexp {.*i_bnet_regs/(stream_base[01]|stream_length|stream_enable|stream_active_buf)_reg.*}] 1
custom_check_count "BNET descriptor capture registers" [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(remaining_bytes_axi|rd_addr_axi|running_axi)_reg.*}] 1
}

custom_check_count "Width frame delay match halves" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/i_frame_delay/match_q_reg\[[01]\]}] 2 2
custom_check_count "Width frame offset mailbox" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/frame_offset_cfg_reg\[[0-9]+\]}] 16 16
custom_check_count "Width frame delay counter" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/i_frame_delay/count_reg\[[0-9]+\]}] 16 16

puts "Collection checks passed. Inspect report_exceptions, report_cdc, report_timing_summary and report_drc before accepting this image."
