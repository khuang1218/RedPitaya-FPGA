# Only pulse_gen's first synchronizer stages are asynchronous endpoints.
# Do not create global asynchronous clock groups: BNET/ADC/DAC share these clocks.
set pulse_first_sync [get_cells -quiet -hier -regexp {.*i_pulse_gen/(request_sync|ack_sync|claim_sync|enable_sync|ready_sync)_reg\[0\]}]
if {[llength $pulse_first_sync] == 5} {
  set_false_path -to [get_pins -of_objects $pulse_first_sync -filter {REF_PIN_NAME == D}]
} else {
  error "pulse_gen: expected five first-stage CDC registers; check active top and synthesized names"
}

# Bundled mailbox values settle before the synchronized request is consumed.
# Keep these real data paths bounded; do not false-path the entire mailbox.
set pulse_mailbox [get_cells -quiet -hier -regexp {.*i_pulse_gen/mailbox_(period|high|enable)_reg(\[[0-9]+\])?}]
set pulse_active [get_cells -quiet -hier -regexp {.*i_pulse_gen/active_(period|high|enable)_reg(\[[0-9]+\])?}]
set pulse_readback [get_cells -quiet -hier -regexp {.*i_pulse_gen/readback_(period|high)_reg\[[0-9]+\]}]
if {[llength $pulse_mailbox] > 0 && [llength $pulse_active] > 0 && [llength $pulse_readback] > 0} {
  set_max_delay -datapath_only 4.000 -from $pulse_mailbox -to $pulse_active
  set_max_delay -datapath_only 8.000 -from $pulse_active -to $pulse_readback
} else {
  error "pulse_gen: bundled-data registers not found; inspect synthesis before adapting these constraints"
}
