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
# A large result array must infer dedicated BRAM; count after synthesis rather
# than accepting LUT/FF expansion. Actual packing/total use is report-dependent.
custom_check_count "Width result BRAM primitives" [get_cells -quiet -hier -filter {NAME =~ *i_tdc/i_width/* && REF_NAME =~ RAMB*}] 1
custom_check_count "Width first CDC stages" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(request_sync|abort_sync|ack_sync|capture_sync|process_sync)_reg\[0\]}] 5 5
custom_check_count "Width reset synchronizer CLR pins" [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_tdc/i_width/fast_reset_pipe_reg\[[0-2]\]}] -filter {REF_PIN_NAME == CLR}] 3 3
custom_check_count "Width configuration mailbox" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(requested_count|timeout_cfg|lut_enabled|clear_request)_reg(\[[0-9]+\])?}] 1
custom_check_count "Width completion metadata" [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(completed_fast|flags_fast)_reg\[[0-9]+\]}] 1
foreach pattern {*i_tdc/return_sync_meta_reg/D *i_tdc/i_internal_stimulus/enable_meta_reg/D *i_tdc/i_mmcm_stimulus/toggle_meta_reg/D *i_tdc/i_mmcm_stimulus/locked_meta_reg/D} {
  custom_check_count $pattern [get_pins -quiet -hier -filter "NAME =~ $pattern"] 1 1
}
custom_check_count "Pulse first CDC stages" [get_cells -quiet -hier -regexp {.*i_pulse_gen/(request_sync|ack_sync|claim_sync|enable_sync|ready_sync|gpio_data_sync)_reg\[0\]}] 6 6
custom_check_count "Pulse reset synchronizer CLR pins" [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_pulse_gen/((bus|fast)_reset_pipe_reg\[[0-2]\]|oddr_rstn_reg)}] -filter {REF_PIN_NAME == CLR}] 7 7
custom_check_count "TDC reset synchronizer CLR pins" [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_mmcm_stimulus/test_rstn*_reg/CLR}] 2 2
custom_check_count "Pulse mailbox" [get_cells -quiet -hier -regexp {.*i_pulse_gen/mailbox_(period|high|last|enable)_reg(\[[0-9]+\])?}] 1
custom_check_count "Pulse active values" [get_cells -quiet -hier -regexp {.*i_pulse_gen/active_(period|high|last|enable)_reg(\[[0-9]+\])?}] 1
custom_check_count "Pulse readback" [get_cells -quiet -hier -regexp {.*i_pulse_gen/readback_(period|high)_reg\[[0-9]+\]}] 1
custom_check_count "BNET first CDC stages" [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(start_toggle_axi_meta|soft_reset_toggle_axi_meta|debug_request_meta|debug_ack_meta)_reg}] 8 8
custom_check_count "BNET debug mailbox" [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/debug_mailbox_axi_reg\[[0-9]+\]}] 1
custom_check_count "BNET debug snapshot" [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(debug0_snapshot|debug1_o)_reg\[[0-9]+\]}] 1
custom_check_count "BNET descriptor registers" [get_cells -quiet -hier -regexp {.*i_bnet_regs/(stream_base[01]|stream_length|stream_enable|stream_active_buf)_reg.*}] 1
custom_check_count "BNET descriptor capture registers" [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(remaining_bytes_axi|rd_addr_axi|running_axi)_reg.*}] 1
puts "Collection checks passed. Inspect report_exceptions, report_cdc, report_timing_summary and report_drc before accepting this image."
