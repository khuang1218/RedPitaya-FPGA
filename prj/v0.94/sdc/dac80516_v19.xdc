# Only the conventional MISO input settling stage is asynchronous. SCLK is an
# output of the 125 MHz sequencer, not a new internal clock. Read commands are
# rejected at periods below 16 bus ticks (64 ns HIGH for worst-case SDO delay).
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *i_dac_spi/miso_meta_reg/D}]
# Dedicated registered outputs, no GPIO/fabric ownership mux after these FFs.
set_property IOB TRUE [get_cells -quiet -hier -regexp {.*i_dac_spi/(sclk_o|mosi_pin|cs_n_o|ldac_n_o)_reg}]
# Bound output routing/skew to preserve the enabled-clock protocol budgets.
# At the shortest 16 ns half-cycle: 4 ns FPGA skew + <=2 ns board skew leaves
# >=10 ns setup/hold. CS setup/hold/gaps are each >=24 ns. Validate on hardware.
set_max_delay -datapath_only 4.000 -from [get_cells -quiet -hier -regexp {.*i_dac_spi/(sclk_o|mosi_pin|cs_n_o|ldac_n_o)_reg}] -to [get_ports {exp_p_io[4] exp_p_io[5] exp_p_io[7] exp_n_io[4]}]
set_property SLEW FAST [get_ports {exp_p_io[4] exp_p_io[5] exp_p_io[7] exp_n_io[4]}]
set_property DRIVE 8 [get_ports {exp_p_io[4] exp_p_io[5] exp_p_io[7] exp_n_io[4]}]
