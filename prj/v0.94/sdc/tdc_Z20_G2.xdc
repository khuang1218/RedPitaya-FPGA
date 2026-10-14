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
