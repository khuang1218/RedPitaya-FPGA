# Implementation only. BNET reader control/snapshot mailboxes cross between
# 125 MHz configuration and 250 MHz AXI clocks. No whole-clock false paths.
set_false_path -to [get_pins -of_objects [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(start_toggle_axi_meta|soft_reset_toggle_axi_meta|debug_request_meta|debug_ack_meta)_reg}] -filter {REF_PIN_NAME == D}]

# Descriptor data stays stable from before START until its synchronized
# request is accepted. Keep the actual bundled data propagation bounded.
set_max_delay -datapath_only 8.000 -from [get_cells -quiet -hier -regexp {.*i_bnet_regs/(stream_base[01]|stream_length|stream_enable|stream_active_buf)_reg.*}] -to [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(remaining_bytes_axi|rd_addr_axi|running_axi)_reg.*}]

# Diagnostic snapshots stay immutable until the returned acknowledgement and
# next request have crossed both synchronizers. They are read in the cfg domain.
set_max_delay -datapath_only 8.000 -from [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/debug_mailbox_axi_reg\[[0-9]+\]}] -to [get_cells -quiet -hier -regexp {.*i_bnet_(sample|weight)_reader/(debug0_snapshot|debug1_o)_reg\[[0-9]+\]}]
