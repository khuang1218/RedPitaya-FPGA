# Implementation only. No Tcl control flow in managed XDC (Vivado 2020.1).
# scripts/check_custom_constraints.tcl checks that these endpoints exist.
set_false_path -to [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_pulse_gen/(request_sync|ack_sync|claim_sync|enable_sync|ready_sync|gpio_data_sync)_reg\[0\]}] -filter {REF_PIN_NAME == D}]

# Asynchronous assertion into reset synchronizers. Final reset release to
# functional flops and to ODDR R remains subject to recovery/removal timing.
set_false_path -to [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_pulse_gen/((bus|fast)_reset_pipe_reg\[[0-2]\]|oddr_rstn_reg)}] -filter {REF_PIN_NAME == CLR}]

# Bundled mailbox data is held until the synchronized acknowledgement returns.
# Bound real data paths instead of masking an entire clock pair.
set_max_delay -datapath_only 4.000 -from [get_cells -quiet -hier -regexp {.*i_pulse_gen/mailbox_(period|high|last|enable)_reg(\[[0-9]+\])?}] -to [get_cells -quiet -hier -regexp {.*i_pulse_gen/active_(period|high|last|enable)_reg(\[[0-9]+\])?}]
set_max_delay -datapath_only 8.000 -from [get_cells -quiet -hier -regexp {.*i_pulse_gen/active_(period|high)_reg\[[0-9]+\]}] -to [get_cells -quiet -hier -regexp {.*i_pulse_gen/readback_(period|high)_reg\[[0-9]+\]}]
