###############################################################################
# TDC timing exceptions for the Z20_G2 E3 return input.
#
# Physical LOC/BEL constraints are deliberately applied by
# scripts/tdc_placement.tcl after the user selects a legal carry column in the
# synthesized Device view.  Do not guess those coordinates in this file.
###############################################################################

set tdc_tap_d_pins [get_pins -quiet -hierarchical -filter {
  NAME =~ *i_tdc/i_carry/gen_tap*/i_tap_ff/D
}]

if {[llength $tdc_tap_d_pins] > 0} {
  # Only the asynchronous E3 input-to-thermometer sampling paths are exempt.
  # Encoder, FIFO, calibration, controller, and register paths remain timed.
  set_false_path -from [get_ports {exp_e3p_i[0] exp_e3n_i[0]}] \
                 -to $tdc_tap_d_pins

  # Hardware self-test is generated in the independent PS fclk[0] domain and
  # intentionally enters the same asynchronous carry-chain measurement node.
  # Keep this exception limited to self-test source registers -> tap D pins.
  set tdc_internal_stimulus_q [get_pins -quiet -hierarchical -filter {
    NAME =~ *i_tdc/i_internal_stimulus*/Q
  }]
  if {[llength $tdc_internal_stimulus_q] > 0} {
    set_false_path -from $tdc_internal_stimulus_q -to $tdc_tap_d_pins
  }

  # Dedicated MMCM phase-sweep self-test source (tdc_mmcm_stimulus.sv). The
  # commanded single edge is deliberately handed across from its
  # dynamically-phase-shifted CLKOUT0 domain into the same asynchronous
  # carry-chain measurement node; only that stimulus-edge-to-tap-D path is
  # exempt, not the PSCLK/PSEN/PSDONE controller or the CLKOUT0-domain
  # synchronizer itself.
  set tdc_mmcm_stimulus_q [get_pins -quiet -hierarchical -filter {
    NAME =~ *i_tdc/i_mmcm_stimulus/event_reg*/Q
  }]
  if {[llength $tdc_mmcm_stimulus_q] > 0} {
    set_false_path -from $tdc_mmcm_stimulus_q -to $tdc_tap_d_pins
  }
}

###############################################################################
# Dedicated MMCM phase-sweep clock. CLKOUT0 regenerates the same nominal
# frequency as clk_i (adc_clk) at a software-commanded, dynamically stepped
# phase. Because that phase is intentionally moved at run time, its relation
# to adc_clk must not be analyzed as a normal generated/related clock: the
# design already carries the resulting edge across through the dedicated
# toggle synchronizer in tdc_mmcm_stimulus.sv, and only that documented path
# is exempted above. Declare the two clocks an asynchronous group so ordinary
# timing analysis does not assume a fixed nominal-phase relationship between
# them.
###############################################################################

set tdc_mmcm_clkout0 [get_pins -quiet -hierarchical -filter {
  NAME =~ *i_tdc/i_mmcm_stimulus/u_mmcm/CLKOUT0
}]

if {[llength $tdc_mmcm_clkout0] > 0} {
  set tdc_adc_clk [get_clocks -quiet -of_objects [get_pins -quiet -hierarchical -filter {
    NAME =~ *i_tdc/clk_i
  }]]
  if {[llength $tdc_adc_clk] == 0} {
    set tdc_adc_clk [get_clocks -quiet adc_clk]
  }

  set tdc_mmcm_clk [get_clocks -quiet -of_objects $tdc_mmcm_clkout0]
  if {[llength $tdc_mmcm_clk] == 0} {
    create_generated_clock -name tdc_mmcm_clkout0 \
      -source [get_pins -quiet -hierarchical -filter {NAME =~ *i_tdc/i_mmcm_stimulus/u_mmcm/CLKIN1}] \
      -multiply_by 1 $tdc_mmcm_clkout0
    set tdc_mmcm_clk [get_clocks -quiet tdc_mmcm_clkout0]
  }

  if {[llength $tdc_adc_clk] > 0 && [llength $tdc_mmcm_clk] > 0} {
    set_clock_groups -quiet -asynchronous -group $tdc_adc_clk -group $tdc_mmcm_clk
  }
}
