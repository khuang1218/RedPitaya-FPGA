# Implementation only; keep managed XDC free of Tcl control flow.
# Vivado 2020.1 skips if blocks in managed XDC. Run the separate
# scripts/check_custom_constraints.tcl to check synthesized collections.

# Tap D pins deliberately sample an asynchronous edge, including the static
# source-selection mux. Tap Q -> encoder/controller, reset, and clocks remain
# timed. Change source selection only while the TDC is disabled.
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_carry/gen_tap*i_tap_ff/D}]

# Exempt only the first D stage of each conventional synchronizer.
# Do not globally group ADC, PS, or phase-swept MMCM clocks.
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *i_tdc/return_sync_meta_reg/D}]
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_internal_stimulus/enable_meta_reg/D}]
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_mmcm_stimulus/toggle_meta_reg/D}]
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_mmcm_stimulus/locked_meta_reg/D}]

# Asynchronous reset assertion into a reset synchronizer is intentional.
# Final synchronized reset paths to functional registers remain timed.
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_mmcm_stimulus/test_rstn*_reg/CLR}]

# PCB pulse-width path: independent 250 MHz carry sampler. Only intentional
# tap D inputs are exempt; capture/encoder/memories/controller remain timed.
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *i_tdc/i_width/i_carry/gen_tap*i_tap_ff/D}]
set_false_path -to [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(request_sync|abort_sync|ack_sync|capture_sync|process_sync)_reg\[0\]}] -filter {REF_PIN_NAME == D}]
set_false_path -to [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_tdc/i_width/fast_reset_pipe_reg\[[0-2]\]}] -filter {REF_PIN_NAME == CLR}]
# Configuration stays fixed until the completion handshake. Result metadata
# stays fixed before the completion toggle and throughout software readout.
set_max_delay -datapath_only 4.000 -from [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(requested_count|timeout_cfg|lut_enabled|clear_request)_reg(\[[0-9]+\])?}] -to [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(target_count|timeout_active|use_lut|state|ack_toggle)_reg(\[[0-9]+\])?}]
set_max_delay -datapath_only 8.000 -from [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(completed_fast|flags_fast)_reg\[[0-9]+\]}] -to [get_cells -quiet -hier -regexp {.*i_tdc/i_width/(completed_bus|flags_bus)_reg\[[0-9]+\]}]
