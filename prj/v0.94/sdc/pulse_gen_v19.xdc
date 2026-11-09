# Implementation only. No Tcl control flow in managed XDC (Vivado 2020.1).
# scripts/check_custom_constraints.tcl checks that these endpoints exist.
set_false_path -to [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_pulse_gen/(request_sync|ack_sync|claim_sync|enable_sync|ready_sync|gpio_data_sync)_reg\[0\]}] -filter {REF_PIN_NAME == D}]

# Asynchronous assertion into reset synchronizers. Final reset release to
# functional flops and to ODDR R remains subject to recovery/removal timing.
set_false_path -to [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_pulse_gen/(bus|fast)_reset_pipe_reg\[[0-2]\]}] -filter {REF_PIN_NAME == CLR}]
# V17 uses an active-high ODDR reset FF, hence asynchronous PRE rather than
# CLR. Only its external assertion input is exempt; FF Q -> ODDR R is timed.
set_false_path -to [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_pulse_gen/oddr_reset_reg}] -filter {REF_PIN_NAME == PRE}]

# Bundled mailbox data is held until the synchronized acknowledgement returns.
# Bound real data paths instead of masking an entire clock pair.
set_max_delay -datapath_only 4.000 -from [get_cells -quiet -hier -regexp {.*i_pulse_gen/mailbox_(period|high|last|prelast|enable|period_two)_reg(\[[0-9]+\])?}] -to [get_cells -quiet -hier -regexp {.*i_pulse_gen/active_(period|high|last|prelast|enable|period_two)_reg(\[[0-9]+\])?}]
# The terminal seed is also part of the same request-held bundled mailbox.
set_max_delay -datapath_only 4.000 -from [get_cells -quiet -hier -regexp {.*i_pulse_gen/mailbox_period_two_reg}] -to [get_cells -quiet -hier -regexp {.*i_pulse_gen/phase_last_match_reg\[[01]\]}]
# ODDR is SAME_EDGE: both D1 and D2 are captured on the rising fast clock.
# The fanout-one source FFs use that same 250 MHz clock, so leave these paths
# under normal single-cycle setup AND hold analysis (including skew/jitter).
# The initial V18 2.5 ns datapath-only placement target was unnecessarily
# stricter than this interface contract and suppressed clock-based analysis.
# No max-delay, multicycle or false-path exception applies to ODDR D1/D2.
set_max_delay -datapath_only 8.000 -from [get_cells -quiet -hier -regexp {.*i_pulse_gen/active_(period|high)_reg\[[0-9]+\]}] -to [get_cells -quiet -hier -regexp {.*i_pulse_gen/readback_(period|high)_reg\[[0-9]+\]}]
