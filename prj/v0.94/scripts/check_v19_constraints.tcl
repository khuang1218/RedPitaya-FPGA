# Run on the actual synthesized/implemented design, never accept empty queries.
proc v19_count {label cells minimum {maximum -1}} {
  set n [llength $cells]
  set expected "at least $minimum"
  if {$maximum>=0} {set expected "$minimum..$maximum"}
  if {$n<$minimum || ($maximum>=0 && $n>$maximum)} {error "$label: expected $expected, found $n"}
  puts "$label: $n"
}
proc v19_check_asg_tables {} {
  foreach ch {chA chB} {
    # Keep independent ownership of each 16384x14 waveform table.
    v19_count "ASG $ch waveform BRAM" [get_cells -quiet -hier -filter "NAME =~ *i_asg/$ch/* && NAME =~ *dac_buf* && REF_NAME =~ RAMB*"] 7
  }
}
proc v19_check_spi_outputs {} {
  foreach signal {sclk_o mosi_pin cs_n_o ldac_n_o} {
    v19_count "SPI $signal dedicated output register" [get_cells -quiet -hier -filter "NAME =~ *i_dac_spi/${signal}_reg && REF_NAME =~ FD*"] 1 1
  }
  # Payload state must not collapse to a constant while control clocks survive.
  v19_count "SPI transmit shift registers" [get_cells -quiet -hier -regexp {.*i_dac_spi/tx_shift_reg\[[0-9]+\]}] 24 24
  v19_count "SPI raw transmit shadow registers" [get_cells -quiet -hier -regexp {.*i_dac_spi/raw_tx_reg\[[0-9]+\]}] 24 24
}
proc v19_check_spi_readback {} {
  foreach stage {miso_meta miso_sync} {
    v19_count "SPI $stage settling register" [get_cells -quiet -hier -filter "NAME =~ *i_dac_spi/${stage}_reg && REF_NAME =~ FD*"] 1 1
    v19_count "SPI $stage D pin" [get_pins -quiet -hier -filter "NAME =~ *i_dac_spi/${stage}_reg/D"] 1 1
  }
  v19_count "SPI receive shift registers" [get_cells -quiet -hier -regexp {.*i_dac_spi/rx_shift_reg\[[0-9]+\]}] 24 24
  v19_count "SPI receive result registers" [get_cells -quiet -hier -regexp {.*i_dac_spi/raw_rx_reg\[[0-9]+\]}] 24 24
}
foreach core {i_tdc0 i_tdc1} {
  foreach chain {i_carry i_width/i_carry i_width/i_fall_carry} {
    v19_count "$core/$chain carries" [get_cells -quiet -hier -filter "REF_NAME == CARRY4 && NAME =~ *$core/$chain/*"] 128 128
    v19_count "$core/$chain samplers" [get_pins -quiet -hier -filter "NAME =~ *$core/$chain/gen_tap*i_tap_ff/D"] 512 512
  }
  v19_count "$core width RAM" [get_cells -quiet -hier -filter "NAME =~ *$core/i_width/* && REF_NAME =~ RAMB*"] 50
  foreach edge {rise fall} {
    v19_count "$core $edge calibration RAM" [get_cells -quiet -hier -filter "NAME =~ *$core/i_width/${edge}_lut* && REF_NAME =~ RAMB*"] 1
    v19_count "$core $edge encoder" [get_cells -quiet -hier -filter "NAME =~ *$core/i_width/i_${edge}_encoder/* && IS_PRIMITIVE == 1"] 1
  }
}
v19_check_asg_tables
v19_count "Pulse ODDR" [get_cells -quiet -hier -filter {NAME =~ *i_pulse_gen/i_oddr && REF_NAME == ODDR}] 1 1
v19_check_spi_outputs
v19_check_spi_readback
v19_count "Removed application engines" [get_cells -quiet -hier -regexp {.*(i_scope/.*|i_pid/.*|i_ams/.*|i_daisy/.*|i_serlines_add/.*|i_bnet_.*|i_butterfly_.*)}] 0 0
foreach name {tdc_v19.xdc tdc_v19_sampler_layout.xdc pulse_gen_v19.xdc dac80516_v19.xdc} {
  set f [get_files -quiet *$name]
  v19_count $name $f 1 1
  if {![get_property USED_IN_IMPLEMENTATION $f]} {error "$name disabled"}
}
puts "V19 structure checks pass; routed timing, DRC and sampler audit are still required."
