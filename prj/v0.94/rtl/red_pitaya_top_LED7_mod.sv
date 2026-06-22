////////////////////////////////////////////////////////////////////////////////
// Red Pitaya TOP module. It connects external pins and PS part with
// other application modules.
// Authors: Matej Oblak, Iztok Jeras
// (c) Red Pitaya  http://www.redpitaya.com
////////////////////////////////////////////////////////////////////////////////

/**
 * GENERAL DESCRIPTION:
 *
 * Top module connects PS part with rest of Red Pitaya applications.  
 *
 *                   /-------\      
 *   PS DDR <------> |  PS   |      AXI <-> custom bus
 *   PS MIO <------> |   /   | <------------+
 *   PS CLK -------> |  ARM  |              |
 *                   \-------/              |
 *                                          |
 *                            /-------\     |
 *                         -> | SCOPE | <---+
 *                         |  \-------/     |
 *                         |                |
 *            /--------\   |   /-----\      |
 *   ADC ---> |        | --+-> |     |      |
 *            | ANALOG |       | PID | <----+
 *   DAC <--- |        | <---- |     |      |
 *            \--------/   ^   \-----/      |
 *                         |                |
 *                         |  /-------\     |
 *                         -- |  ASG  | <---+ 
 *                            \-------/     |
 *                                          |
 *             /--------\                   |
 *    RX ----> |        |                   |
 *   SATA      | DAISY  | <-----------------+
 *    TX <---- |        | 
 *             \--------/ 
 *               |    |
 *               |    |
 *               (FREE)
 *
 * Inside analog module, ADC data is translated from unsigned neg-slope into
 * two's complement. Similar is done on DAC data.
 *
 * Scope module stores data from ADC into RAM. In the original Red Pitaya signal
 * path, arbitrary signal generator (ASG) and MIMO PID can feed the DAC. In this
 * modified file, the butterfly-network milestone uses one ASG waveform stream
 * as a sequence of neighboring sample pairs, computes sum/difference within
 * each pair, and sends those results to the DAC.
 *
 * Daisy chain connects with other boards with fast serial link. Data which is
 * send and received is at the moment undefined. This is left for the user.
 */

module red_pitaya_top #(
  // Parameters are compile-time constants. They let the same source file be
  // built for slightly different Red Pitaya boards without changing the logic
  // below. For example, ADW selects the ADC sample width and DWE selects how
  // many expansion connector pins exist on this board variant.
  // identification
  bit [0:5*32-1] GITH = '0,
  // module numbers
  parameter MNA = 2,  // number of acquisition modules
  parameter MNG = 2,  // number of generator   modules
  parameter ADW_125 = 14,
  parameter ADW_122 = 16,
  parameter DWE_Z20 = 11,
  parameter DWE_Z10 = 8,
  parameter DDW     = 14,
`ifdef Z20_122
  parameter ADW=ADW_122,
  parameter ADC_DW=ADW_122,
`else
  parameter ADW=ADW_125,
  parameter ADC_DW=ADW_125,
`endif
`ifdef Z20_xx
  parameter DWE=DWE_Z20
`else
  parameter DWE=DWE_Z10
`endif


)(
  // This is the top-level port list. Every signal here is an actual FPGA pin
  // or a bundle connected to the Zynq Processing System (PS). Signals declared
  // as "inout" can be driven in both directions, which is common for DDR, MIO,
  // and configurable GPIO pins.

  // PS connections
  inout  logic [54-1:0] FIXED_IO_mio     ,
  inout  logic          FIXED_IO_ps_clk  ,
  inout  logic          FIXED_IO_ps_porb ,
  inout  logic          FIXED_IO_ps_srstb,
  inout  logic          FIXED_IO_ddr_vrn ,
  inout  logic          FIXED_IO_ddr_vrp ,
  // DDR
  inout  logic [15-1:0] DDR_addr   ,
  inout  logic [ 3-1:0] DDR_ba     ,
  inout  logic          DDR_cas_n  ,
  inout  logic          DDR_ck_n   ,
  inout  logic          DDR_ck_p   ,
  inout  logic          DDR_cke    ,
  inout  logic          DDR_cs_n   ,
  inout  logic [ 4-1:0] DDR_dm     ,
  inout  logic [32-1:0] DDR_dq     ,
  inout  logic [ 4-1:0] DDR_dqs_n  ,
  inout  logic [ 4-1:0] DDR_dqs_p  ,
  inout  logic          DDR_odt    ,
  inout  logic          DDR_ras_n  ,
  inout  logic          DDR_reset_n,
  inout  logic          DDR_we_n   ,

  // Red Pitaya periphery

  // ADC
  input  logic [MNA-1:0] [16-1:0] adc_dat_i,  // ADC data
  input  logic           [ 2-1:0] adc_clk_i,  // ADC clock {p,n}
  output logic           [ 2-1:0] adc_clk_o,  // optional ADC clock source (unused) [0] = p; [1] = n
  output logic                    adc_cdcs_o, // ADC clock duty cycle stabilizer
  // DAC
  output logic [ 14-1:0] dac_dat_o  ,  // DAC combined data
  output logic           dac_wrt_o  ,  // DAC write
  output logic           dac_sel_o  ,  // DAC channel select
  output logic           dac_clk_o  ,  // DAC clock
  output logic           dac_rst_o  ,  // DAC reset
  // PWM DAC
  output logic [  4-1:0] dac_pwm_o  ,  // 1-bit PWM DAC
  // XADC
  input  logic [  5-1:0] vinp_i     ,  // voltages p
  input  logic [  5-1:0] vinn_i     ,  // voltages n
  // Expansion connector
  inout  logic [DWE-1:0] exp_p_io  ,
  inout  logic [DWE-1:0] exp_n_io  ,
  // SATA connector
  output logic [  2-1:0] daisy_p_o  ,  // line 1 is clock capable
  output logic [  2-1:0] daisy_n_o  ,
  input  logic [  2-1:0] daisy_p_i  ,  // line 1 is clock capable
  input  logic [  2-1:0] daisy_n_i  ,

  `ifdef Z20_G2
  // Additional E3 connector
  output logic [  4-1:0] exp_e3p_o  ,  // line 3 is clock capable (SRCC)
  output logic [  4-1:0] exp_e3n_o  ,
  input  logic [  4-1:0] exp_e3p_i  ,  // line 3 is clock capable (MRCC)
  input  logic [  4-1:0] exp_e3n_i  ,

  input  logic           s1_orient_i ,
  input  logic           s1_link_i   ,
  `endif
  // LED
  output  logic [  8-1:0] led_o
);

////////////////////////////////////////////////////////////////////////////////
// local signals
////////////////////////////////////////////////////////////////////////////////

// Local signals are internal wires/registers used to connect the larger blocks
// together. In SystemVerilog, "logic" can be assigned by either continuous
// assignments or procedural always blocks, depending on how it is used.

// GPIO input data width. This mirrors DWE so later code can talk about GPIO
// bus width without tying the name to the physical expansion connector width.
localparam int unsigned GDW = DWE;

// RST_MAX controls how long the FPGA holds some internal logic in reset after
// the PLL reports that its output clocks are stable. The counter below counts
// adc_clk cycles up to this value.
localparam RST_MAX = 64;

// fclk/frstn are clocks and resets generated by the Zynq PS block. The comment
// lists the intended frequencies of each clock lane. fclk[0] is the main
// 125 MHz PS/system clock used by the control bus.
logic [4-1:0] fclk ; //[0]-125MHz, [1]-250MHz, [2]-50MHz, [3]-200MHz
logic [4-1:0] frstn;

// Parallel data received from the daisy-chain serial link.
logic [16-1:0] par_dat;

// Trigger/control signals shared between GPIO, scope, ASG, and the daisy-chain
// connector. "trig_ext" is the external trigger used by the acquisition and
// generator modules after local/daisy trigger selection has been applied.
logic          daisy_trig;
logic [ 3-1:0] daisy_mode;
logic          trig_ext;
logic          trig_output_sel;
logic          trig_asg_out;
logic [ 4-1:0] trig_ext_asg01;



// PLL signals. The ADC provides the board's high-quality sampling clock. This
// design feeds that clock into a PLL, then uses the PLL to create the related
// ADC, DAC, serial, and PWM clocks that need specific frequencies/phases.
logic                 adc_clk_in;
logic                 pll_adc_clk;
logic                 pll_dac_clk_1x;
logic                 pll_dac_clk_2x;
logic                 pll_dac_clk_2p;
logic                 pll_ser_clk;
logic                 pll_pwm_clk;
logic                 pll_locked;
logic                 pll_locked_r;
logic                 fpll_locked_r,fpll_locked_r2,fpll_locked_r3;

logic   [16-1:0]      rst_cnt = 'h0;
logic                 rst_after_locked;
logic                 rstn_pll;

// fast serial signals. ser_clk is used by the daisy-chain SERDES-style logic.
logic                 ser_clk ;
// PWM clock and reset. These are used by the low-speed 1-bit DAC/PDM outputs.
logic                 pwm_clk ;
logic                 pwm_rstn;

// ADC clock/reset. Most of the "measurement path" logic in this file runs on
// adc_clk. adc_rstn is active low, so 0 means reset and 1 means running.
logic                 adc_clk;
logic                 adc_rstn;
logic                 adc_clk_daisy;
logic                 scope_trigo;

// CAN bus signals. The PS owns the CAN controllers, while this FPGA top-level
// routes the CAN RX/TX pins to expansion connector pins when can_on is enabled.
logic                 CAN0_rx, CAN0_tx;
logic                 CAN1_rx, CAN1_tx;
logic                 can_on;


// Stream sample types. SBA_T is the signed ADC/acquisition sample type and
// SBG_T is the signed generator/DAC sample type. Using typedef-like localparam
// types keeps all channel arrays consistently sized.
localparam type SBA_T = logic signed [ADW-1:0];  // acquire
localparam type SBG_T = logic signed [ 14-1:0];  // generate
localparam int unsigned BNET_STREAM_COUNT = 8;
localparam int unsigned BNET_SERIAL_VECTOR_LEN = 2048;
// The frame-pipeline architecture keeps per-stage output banks and per-stage
// weight RAMs in fabric. 16384 was intentionally tried as a stress target, but
// it over-utilizes the Zynq-7020 LUTRAM/mux fabric by a wide margin. Use 4096
// as the next practical compile target, then step upward only if utilization
// has clear headroom.
localparam int unsigned BNET_PIPE_VECTOR_LEN = 4096;

// Converted ADC samples used inside the FPGA. The raw ADC pins are unsigned
// "negative slope" format, but most DSP/control logic wants signed values.
SBA_T [MNA-1:0]          adc_dat;

// Butterfly-network output. The module treats ASG channel A as the input vector
// stream and ASG channel B as a packed weight stream. For each input sample,
// ASG B carries two signed 7-bit weights:
// - asg_dat[1][13:7] = that sample's contribution to butterfly_dat[0]
// - asg_dat[1][ 6:0] = that sample's contribution to butterfly_dat[1]
// The first stage consumes neighboring pairs, so every two clocks produce a
// weighted two-output butterfly result.
SBG_T [2-1:0]            butterfly_dat;
SBG_T                    bnet_sample_dat;
logic signed [14-1:0]    bnet_weight_dat;
logic [2-1:0]            bnet_input_sel;
logic                    bnet_static_weight_reuse;
logic                    bnet_static_pipeline_en;
logic                    bnet_static_pipeline_active;
logic                    bnet_single_dac_output_en;
logic                    bnet_start_pulse;
logic                    bnet_soft_reset_pulse;
logic [4-1:0]            bnet_start_stretch;
logic                    bnet_start_run;
logic                    bnet_start;
logic                    bnet_sample_valid;
logic                    bnet_weight_valid;
logic                    bnet_sample_ready;
logic                    bnet_weight_ready;
logic                    bnet_output_valid;
logic                    bnet_busy;
logic                    bnet_done;
logic [32-1:0]           bnet_time_total_cycles;
logic [32-1:0]           bnet_time_load_cycles;
logic [32-1:0]           bnet_time_compute_cycles;
logic [32-1:0]           bnet_time_playback_cycles;
logic [32-1:0]           bnet_time_input_load_cycles;
logic [32-1:0]           bnet_time_latency_cycles;
SBG_T [2-1:0]            bnet_serial_dat;
logic                    bnet_serial_sample_ready;
logic                    bnet_serial_weight_ready;
logic                    bnet_serial_output_valid;
logic                    bnet_serial_output_ready;
logic                    bnet_serial_busy;
logic                    bnet_serial_done;
logic [32-1:0]           bnet_serial_time_total_cycles;
logic [32-1:0]           bnet_serial_time_load_cycles;
logic [32-1:0]           bnet_serial_time_compute_cycles;
logic [32-1:0]           bnet_serial_time_playback_cycles;
SBG_T [2-1:0]            bnet_pipe_dat;
logic                    bnet_pipe_sample_ready;
logic                    bnet_pipe_weight_ready;
logic                    bnet_pipe_weight_done;
logic                    bnet_pipe_output_valid;
logic                    bnet_pipe_output_ready;
logic                    bnet_pipe_busy;
logic                    bnet_pipe_done;
logic [32-1:0]           bnet_pipe_time_output_cycles;
logic [32-1:0]           bnet_pipe_time_total_cycles;
logic [32-1:0]           bnet_pipe_time_weight_load_cycles;
logic [32-1:0]           bnet_pipe_time_input_load_cycles;
logic [32-1:0]           bnet_pipe_time_latency_cycles;
logic                    bnet_weight_stream_active;
logic signed [14-1:0]    bnet_ddr_sample_dat;
logic signed [14-1:0]    bnet_ddr_weight_dat;
logic                    bnet_ddr_sample_valid;
logic                    bnet_ddr_weight_valid;
logic [32-1:0]           bnet_ddr_sample_rptr;
logic [32-1:0]           bnet_ddr_weight_rptr;
logic [32-1:0]           bnet_ddr_sample_debug0;
logic [32-1:0]           bnet_ddr_sample_debug1;
logic [32-1:0]           bnet_ddr_weight_debug0;
logic [32-1:0]           bnet_ddr_weight_debug1;
logic                    bnet_ddr_sample_underrun;
logic                    bnet_ddr_weight_underrun;
logic [BNET_STREAM_COUNT-1:0][32-1:0] bnet_stream_base0;
logic [BNET_STREAM_COUNT-1:0][32-1:0] bnet_stream_base1;
logic [BNET_STREAM_COUNT-1:0][32-1:0] bnet_stream_length;
logic [BNET_STREAM_COUNT-1:0][32-1:0] bnet_stream_stride;
logic [BNET_STREAM_COUNT-1:0][32-1:0] bnet_stream_format;
logic [BNET_STREAM_COUNT-1:0][32-1:0] bnet_stream_read_ptr;
logic [BNET_STREAM_COUNT-1:0][32-1:0] bnet_stream_debug0;
logic [BNET_STREAM_COUNT-1:0][32-1:0] bnet_stream_debug1;
logic [BNET_STREAM_COUNT-1:0]          bnet_stream_enable;
logic [BNET_STREAM_COUNT-1:0]          bnet_stream_active_buf;
logic [BNET_STREAM_COUNT-1:0]          bnet_stream_runtime_error;

// DAC signals
logic                    dac_clk_1x;
logic                    dac_clk_2x;
logic                    dac_clk_2p;
logic                    dac_axi_clk;
logic                    dac_rst;
logic                    dac_axi_rstn;

logic        [14-1:0] dac_dat_a, dac_dat_b;
logic        [14-1:0] dac_a    , dac_b    ;
logic signed [15-1:0] dac_a_sum, dac_b_sum;
SBG_T [2-1:0] bnet_dac_dat;
SBG_T         bnet_single_dac_hold;
logic         bnet_single_dac_hold_valid;

// ASG outputs. ASG means Arbitrary Signal Generator. Software can load waveform
// samples into memory through SCPI/API, then the ASG streams those samples out
// here. In this milestone ASG channel A feeds the neighboring-pair butterfly
// network instead of going directly to the DAC.
SBG_T [2-1:0]            asg_dat;

// PID outputs. The PID controller is still instantiated and software-visible,
// but its correction samples are bypassed by the first butterfly milestone.
SBA_T [2-1:0]            pid_dat;

// Configuration bits written by software through the housekeeping block.
// digital_loop[0] loops DAC data back into the ADC path.
// digital_loop[1] loops ADC data forward into the DAC path.
logic [2-1:0]            digital_loop;

// System bus interfaces. ps_sys is the single bus from the ARM/PS side. The
// interconnect below decodes it into sys[0]..sys[7], one region per FPGA block.
sys_bus_if   ps_sys      (.clk (fclk[0]), .rstn (frstn[0]));
sys_bus_if   sys [8-1:0] (.clk (adc_clk), .rstn (adc_rstn));

// GPIO interface to the PS. Width is 3*GDW because it carries multiple GPIO
// groups, not just one physical connector bank.
gpio_if #(.DW (3*GDW)) gpio ();

// AXI masters used by high-throughput blocks. The scope writes captured ADC
// samples to DDR through axi0/axi1. The ASG reads waveform samples from DDR
// through axi2/axi3.
axi_sys_if axi0_sys (.clk(adc_clk    ), .rstn(adc_rstn    ));
axi_sys_if axi1_sys (.clk(adc_clk    ), .rstn(adc_rstn    ));
axi_sys_if axi2_sys (.clk(dac_axi_clk), .rstn(dac_axi_rstn));
axi_sys_if axi3_sys (.clk(dac_axi_clk), .rstn(dac_axi_rstn));
axi_sys_if asg_axi_a_dummy (.clk(dac_axi_clk), .rstn(dac_axi_rstn));
axi_sys_if asg_axi_b_dummy (.clk(dac_axi_clk), .rstn(dac_axi_rstn));

assign asg_axi_a_dummy.werr  = 1'b0;
assign asg_axi_a_dummy.wrdy  = 1'b1;
assign asg_axi_a_dummy.rdata = 64'd0;
assign asg_axi_a_dummy.rerr  = 1'b0;
assign asg_axi_a_dummy.rrdym = 1'b1;
assign asg_axi_a_dummy.rardy = 1'b1;
assign asg_axi_b_dummy.werr  = 1'b0;
assign asg_axi_b_dummy.wrdy  = 1'b1;
assign asg_axi_b_dummy.rdata = 64'd0;
assign asg_axi_b_dummy.rerr  = 1'b0;
assign asg_axi_b_dummy.rrdym = 1'b1;
assign asg_axi_b_dummy.rardy = 1'b1;
assign bnet_stream_read_ptr[0] = bnet_ddr_sample_rptr;
assign bnet_stream_read_ptr[1] = bnet_ddr_weight_rptr;
assign bnet_stream_debug0[0] = bnet_ddr_sample_debug0;
assign bnet_stream_debug0[1] = bnet_ddr_weight_debug0;
assign bnet_stream_debug1[0] = bnet_ddr_sample_debug1;
assign bnet_stream_debug1[1] = bnet_ddr_weight_debug1;
assign bnet_stream_runtime_error = {
  {(BNET_STREAM_COUNT-2){1'b0}},
  bnet_ddr_weight_underrun,
  bnet_ddr_sample_underrun
};

assign bnet_static_pipeline_active = bnet_static_pipeline_en && (bnet_input_sel == 2'd2);
assign bnet_weight_stream_active = bnet_static_pipeline_active ? !bnet_pipe_weight_done :
                                                             !bnet_static_weight_reuse;
assign bnet_sample_ready = bnet_static_pipeline_active ? bnet_pipe_sample_ready :
                                                     bnet_serial_sample_ready;
assign bnet_weight_ready = bnet_static_pipeline_active ? bnet_pipe_weight_ready :
                                                     bnet_serial_weight_ready;
assign butterfly_dat[0] = bnet_static_pipeline_active ? bnet_pipe_dat[0] : bnet_serial_dat[0];
assign butterfly_dat[1] = bnet_static_pipeline_active ? bnet_pipe_dat[1] : bnet_serial_dat[1];
assign bnet_output_valid = bnet_static_pipeline_active ? bnet_pipe_output_valid :
                                                     bnet_serial_output_valid;
assign bnet_busy = bnet_static_pipeline_active ? bnet_pipe_busy : bnet_serial_busy;
assign bnet_done = bnet_static_pipeline_active ? bnet_pipe_done : bnet_serial_done;
assign bnet_time_total_cycles = bnet_static_pipeline_active ? bnet_pipe_time_total_cycles :
                                                          bnet_serial_time_total_cycles;
assign bnet_time_load_cycles = bnet_static_pipeline_active ? bnet_pipe_time_weight_load_cycles :
                                                         bnet_serial_time_load_cycles;
assign bnet_time_compute_cycles = bnet_static_pipeline_active ? bnet_pipe_time_input_load_cycles :
                                                            bnet_serial_time_compute_cycles;
assign bnet_time_playback_cycles = bnet_static_pipeline_active ? bnet_pipe_time_output_cycles :
                                                             bnet_serial_time_playback_cycles;
assign bnet_time_input_load_cycles = bnet_static_pipeline_active ? bnet_pipe_time_input_load_cycles :
                                                               bnet_serial_time_load_cycles;
assign bnet_time_latency_cycles = bnet_static_pipeline_active ? bnet_pipe_time_latency_cycles :
                                                           bnet_serial_time_compute_cycles;
assign bnet_serial_output_ready = !bnet_single_dac_output_en || !bnet_single_dac_hold_valid;
assign bnet_pipe_output_ready = !bnet_single_dac_output_en || !bnet_single_dac_hold_valid;

always_ff @(posedge adc_clk) begin
  if (!adc_rstn || bnet_soft_reset_pulse) begin
    bnet_start_stretch <= 4'd0;
  end else if (bnet_start_pulse && (bnet_input_sel == 2'd2)) begin
    bnet_start_stretch <= 4'hf;
  end else begin
    bnet_start_stretch <= {1'b0, bnet_start_stretch[3:1]};
  end
end

assign bnet_start_run = (bnet_input_sel == 2'd2) ? |bnet_start_stretch :
                                                     bnet_start_pulse;

generate
for (genvar BNET_RPTR_IDX = 2; BNET_RPTR_IDX < BNET_STREAM_COUNT; BNET_RPTR_IDX++) begin : bnet_unused_rptr
  assign bnet_stream_read_ptr[BNET_RPTR_IDX] = 32'd0;
  assign bnet_stream_debug0[BNET_RPTR_IDX] = 32'd0;
  assign bnet_stream_debug1[BNET_RPTR_IDX] = 32'd0;
end
endgenerate
////////////////////////////////////////////////////////////////////////////////
// PLL (clock and reset)
////////////////////////////////////////////////////////////////////////////////

// The ADC clock arrives on two pins as a differential pair: one positive and
// one negative signal. IBUFDS is a Xilinx primitive that converts that physical
// differential input into one normal internal FPGA clock signal.
//
// Note the pin order used here: adc_clk_i[1] is connected to I and adc_clk_i[0]
// is connected to IB. That matches the board constraints/pinout.
IBUFDS i_clk (.I (adc_clk_i[1]), .IB (adc_clk_i[0]), .O (adc_clk_in));  // differential clock input

// Reset the PLL when the PS reset is active. The fpll_locked_r* registers below
// also detect a falling edge of pll_locked in the fclk[0] domain; this causes a
// short PLL reset if lock was lost.
assign rstn_pll = frstn[0] & ~(!fpll_locked_r2 && fpll_locked_r3);

// red_pitaya_pll creates all clocks that must be phase/frequency related to
// the ADC clock. The DAC needs multiple related clocks:
// - 1x: data/channel-rate logic
// - 2x: write strobe timing
// - 2p: phase-shifted clock for DAC clock output timing
red_pitaya_pll pll (
  // inputs
  .clk         (adc_clk_in),  // clock
  .rstn        (rstn_pll  ),  // reset - active low
  // output clocks
  .clk_adc     (pll_adc_clk   ),  // ADC clock
  .clk_dac_1x  (pll_dac_clk_1x),  // DAC clock 125MHz
  .clk_dac_2x  (pll_dac_clk_2x),  // DAC clock 250MHz
  .clk_dac_2p  (pll_dac_clk_2p),  // DAC clock 250MHz -45DGR
  .clk_ser     (pll_ser_clk   ),  // fast serial clock
  .clk_pdm     (pll_pwm_clk   ),  // PWM clock
  // status outputs
  .pll_locked  (pll_locked    )
);

// BUFG is a global clock buffer. FPGA clock nets must be routed on special
// low-skew resources; BUFG promotes the raw PLL output clocks onto those clock
// networks so many flip-flops can safely use them.
BUFG bufg_adc_clk     (.O (adc_clk    ), .I (pll_adc_clk   ));
BUFG bufg_dac_clk_1x  (.O (dac_clk_1x ), .I (pll_dac_clk_1x));
BUFG bufg_dac_clk_2x  (.O (dac_clk_2x ), .I (pll_dac_clk_2x));
BUFG bufg_dac_axi_clk (.O (dac_axi_clk), .I (pll_dac_clk_2x));

BUFG bufg_dac_clk_2p (.O (dac_clk_2p), .I (pll_dac_clk_2p));
BUFG bufg_ser_clk    (.O (ser_clk   ), .I (pll_ser_clk   ));
BUFG bufg_pwm_clk    (.O (pwm_clk   ), .I (pll_pwm_clk   ));

// Synchronize pll_locked into the PS fclk[0] clock domain. Any time a signal
// crosses from one clock domain to another, registering it a few times reduces
// the chance of metastability causing bad logic decisions.
always @(posedge fclk[0]) begin
  fpll_locked_r   <= pll_locked;
  fpll_locked_r2  <= fpll_locked_r;
  fpll_locked_r3  <= fpll_locked_r2;
end

// Generate a short reset pulse after the PLL first locks. pll_locked says the
// PLL output clocks are valid, but downstream logic still benefits from being
// held in reset for a few clock cycles after that moment.
always @(posedge adc_clk) begin
  pll_locked_r      <= pll_locked;
  if ((pll_locked && !pll_locked_r) || rst_cnt > 0) begin // some clk cycles after rising edge of pll_locked
    if (rst_cnt < RST_MAX)
      rst_cnt <= rst_cnt + 1;
    else 
      rst_cnt <= 'h0;
  end else begin
    if (~pll_locked) begin
      rst_cnt <= 'h0;
    end
  end
end

assign rst_after_locked = |rst_cnt;

// The resets below are registered in the clock domain where they will be used.
// This is a common FPGA style: each clock domain gets its own reset signal with
// timing that is clean relative to that clock.
//
// Naming convention here:
// - signals ending in "rstn" are active low: 0 = reset, 1 = run
// - dac_rst is active high: 1 = reset, 0 = run
// ADC reset (active low)
always @(posedge adc_clk)
adc_rstn     <=  frstn[0] & ~rst_after_locked;

// DAC reset (active high)
always @(posedge dac_clk_1x)
dac_rst      <= ~frstn[0] |  rst_after_locked;

// DAC AXI reset (active low)
always @(posedge dac_axi_clk)
dac_axi_rstn <=  frstn[0] & ~rst_after_locked;

// PWM reset (active low)
always @(posedge pwm_clk)
pwm_rstn     <=  frstn[0] & ~rst_after_locked;

////////////////////////////////////////////////////////////////////////////////
//  Connections to PS
////////////////////////////////////////////////////////////////////////////////

// This block is the Zynq Processing System wrapper. It connects the FPGA fabric
// to the ARM CPU, DDR memory, MIO pins, XADC, GPIO, AXI ports, and the custom
// Red Pitaya system bus. In practical terms, this is how Linux/software running
// on the Red Pitaya can configure and read back the FPGA blocks below.
red_pitaya_ps ps (
  .FIXED_IO_mio       (  FIXED_IO_mio                ),
  .FIXED_IO_ps_clk    (  FIXED_IO_ps_clk             ),
  .FIXED_IO_ps_porb   (  FIXED_IO_ps_porb            ),
  .FIXED_IO_ps_srstb  (  FIXED_IO_ps_srstb           ),
  .FIXED_IO_ddr_vrn   (  FIXED_IO_ddr_vrn            ),
  .FIXED_IO_ddr_vrp   (  FIXED_IO_ddr_vrp            ),
  // DDR
  .DDR_addr      (DDR_addr    ),
  .DDR_ba        (DDR_ba      ),
  .DDR_cas_n     (DDR_cas_n   ),
  .DDR_ck_n      (DDR_ck_n    ),
  .DDR_ck_p      (DDR_ck_p    ),
  .DDR_cke       (DDR_cke     ),
  .DDR_cs_n      (DDR_cs_n    ),
  .DDR_dm        (DDR_dm      ),
  .DDR_dq        (DDR_dq      ),
  .DDR_dqs_n     (DDR_dqs_n   ),
  .DDR_dqs_p     (DDR_dqs_p   ),
  .DDR_odt       (DDR_odt     ),
  .DDR_ras_n     (DDR_ras_n   ),
  .DDR_reset_n   (DDR_reset_n ),
  .DDR_we_n      (DDR_we_n    ),
  // system signals
  .fclk_clk_o    (fclk        ),
  .fclk_rstn_o   (frstn       ),
  // ADC analog inputs
  .vinp_i        (vinp_i      ),
  .vinn_i        (vinn_i      ),
  // CAN0
  .CAN0_rx       (CAN0_rx     ),
  .CAN0_tx       (CAN0_tx     ),
  // CAN1
  .CAN1_rx       (CAN1_rx     ),
  .CAN1_tx       (CAN1_tx     ),
  // GPIO
  .gpio          (gpio),
  // system read/write channel
  .bus           (ps_sys      ),
  // AXI masters

  .axi0_sys      (axi0_sys    ),
  .axi1_sys      (axi1_sys    ),
  .axi2_sys      (axi2_sys    ),
  .axi3_sys      (axi3_sys    )
);

////////////////////////////////////////////////////////////////////////////////
// system bus decoder & multiplexer (it breaks memory addresses into 8 regions)
////////////////////////////////////////////////////////////////////////////////

// Software sees one memory-mapped FPGA control bus coming from the PS. This
// interconnect decodes address bits and routes each transaction to one of eight
// slave buses:
//   sys[0] housekeeping/GPIO/control
//   sys[1] oscilloscope
//   sys[2] arbitrary signal generator
//   sys[3] PID controller
//   sys[4] analog mixed-signal/PWM DAC config
//   sys[5] daisy-chain link
//   sys[6], sys[7] optional/unused depending on build
sys_bus_interconnect #(
  .SN (8),
  .SW (20)
) sys_bus_interconnect (
  .pll_locked_i(pll_locked),
  .bus_m (ps_sys),
  .bus_s (sys)
);


`ifndef SCOPE_ONLY

// In normal builds, include the complete application path: housekeeping, ADC,
// DAC, scope, ASG, PID, GPIO, and daisy-chain. If SCOPE_ONLY is defined at
// compile time, the simplified block near the bottom is used instead.

// Any nonzero daisy-chain receive word is treated as a trigger marker.
assign daisy_trig = |par_dat;

// External trigger normally comes from the expansion GPIO input. In daisy sync
// mode, a local GPIO trigger is suppressed when a daisy-chain trigger is active,
// preventing both sources from fighting over the trigger decision.
assign trig_ext   = gpio.i[GDW] & ~(daisy_mode[0] & daisy_trig);
////////////////////////////////////////////////////////////////////////////////
// Analog mixed signals (PDM analog outputs)
////////////////////////////////////////////////////////////////////////////////

// pdm_cfg holds four 8-bit duty/settings values for the slow analog outputs.
// The AMS block exposes these registers to software through sys[4].
logic [4-1:0] [8-1:0] pdm_cfg;

// AMS = Analog Mixed Signals. Here it is mainly used to provide configurable
// values for the 4 slow DAC/PWM outputs on the Red Pitaya.
red_pitaya_ams i_ams (
  // power test
  .clk_i           (adc_clk ),  // clock
  .rstn_i          (adc_rstn),  // reset - active low
  // PWM configuration
  .dac_a_o         (pdm_cfg[0]),
  .dac_b_o         (pdm_cfg[1]),
  .dac_c_o         (pdm_cfg[2]),
  .dac_d_o         (pdm_cfg[3]),
  // System bus
  .sys_addr        (sys[4].addr ),
  .sys_wdata       (sys[4].wdata),
  .sys_wen         (sys[4].wen  ),
  .sys_ren         (sys[4].ren  ),
  .sys_rdata       (sys[4].rdata),
  .sys_err         (sys[4].err  ),
  .sys_ack         (sys[4].ack  )
);

// PDM = pulse-density modulation. It turns each 8-bit value in pdm_cfg into a
// 1-bit output whose density over time represents the analog value. External
// filtering on the board turns that bitstream into a low-speed analog voltage.
red_pitaya_pdm pdm (
  // system signals
  .clk   (adc_clk ),
  .rstn  (adc_rstn),
  // configuration
  .cfg   (pdm_cfg),
  .ena      (1'b1),
  .rng      (8'd255),
  // PWM outputs
  .pdm (dac_pwm_o)
);

////////////////////////////////////////////////////////////////////////////////
// ADC IO
////////////////////////////////////////////////////////////////////////////////

// ODDR is an output double-data-rate register. It drives D1 on one clock edge
// and D2 on the other, so alternating 1/0 creates a clock-like output waveform.
// Here the design forwards adc_clk_daisy out as a differential-style ADC clock
// pair: adc_clk_o[0] toggles opposite of adc_clk_o[1].
ODDR i_adc_clk_p ( .Q(adc_clk_o[0]), .D1(1'b1), .D2(1'b0), .C(adc_clk_daisy), .CE(1'b1), .R(1'b0), .S(1'b0));
ODDR i_adc_clk_n ( .Q(adc_clk_o[1]), .D1(1'b0), .D2(1'b1), .C(adc_clk_daisy), .CE(1'b1), .R(1'b0), .S(1'b0));

// Enable the ADC clock duty-cycle stabilizer. This is a board-level ADC control
// pin; tying it high leaves the stabilizer enabled.
assign adc_cdcs_o = 1'b1 ;

logic [2-1:0] [ADW-1:0] adc_dat_raw;

// IO block registers should be used here
// lowest 2 bits reserved for 16bit ADC

// Take the top ADW bits from each 16-bit ADC input word. The "-:" part-select
// syntax means "start at this bit and count downward".
// Example with ADW=14:
//   adc_dat_i[0][16-1 -: ADW] == adc_dat_i[0][15:2]
// The lowest two bits are ignored on 14-bit ADC builds.
assign adc_dat_raw[0] = adc_dat_i[0][16-1 -: ADW];
assign adc_dat_raw[1] = adc_dat_i[1][16-1 -: ADW];

// Convert raw ADC format into signed two's-complement samples.
//
// Red Pitaya ADC data is encoded as "negative slope": the sign bit is kept, but
// the remaining magnitude bits are inverted. The concatenation below keeps the
// MSB and bitwise-inverts the lower bits:
//   {adc_dat_raw[x][ADW-1], ~adc_dat_raw[x][ADW-2:0]}
//
// The ternary operator chooses between two sources:
//   digital_loop[0] == 1: use the current DAC signal as fake ADC input
//   digital_loop[0] == 0: use real ADC pins
// This loopback is useful for testing the internal data path without external
// cables or analog signals.
always @(posedge adc_clk) begin
  adc_dat[0] <= digital_loop[0] ? dac_a : {adc_dat_raw[0][ADW-1], ~adc_dat_raw[0][ADW-2:0]};
  adc_dat[1] <= digital_loop[0] ? dac_b : {adc_dat_raw[1][ADW-1], ~adc_dat_raw[1][ADW-2:0]};
end
//always @(posedge adc_clk) begin
  //adc_dat[0] <= digital_loop[0] ? dac_a : adc_dat_raw[0];
  //adc_dat[1] <= digital_loop[0] ? dac_b : adc_dat_raw[1];
//end

////////////////////////////////////////////////////////////////////////////////
// DAC IO
////////////////////////////////////////////////////////////////////////////////

// BNET DDR streams. Stream 0 is the sample/input stream and stream 1 is the
// packed-weight stream. They use the two PS HP ports that normally back ASG
// deep-memory generation; normal ASG table mode remains available through BRAM.
bnet_axi_reader_ch #(
  .SAMPLE_DW (14)
) i_bnet_sample_reader (
  .cfg_clk_i      (adc_clk),
  .cfg_rstn_i     (adc_rstn),
  .soft_reset_i   (bnet_soft_reset_pulse),
  .start_i        (bnet_start_run && (bnet_input_sel == 2'd2)),
  .enable_i       (bnet_stream_enable[0]),
  .active_buf_i   (bnet_stream_active_buf[0]),
  .base0_i        (bnet_stream_base0[0]),
  .base1_i        (bnet_stream_base1[0]),
  .length_bytes_i (bnet_stream_length[0]),
  .stride_bytes_i (bnet_stream_stride[0]),
  .consume_i      ((bnet_input_sel == 2'd2) && bnet_sample_ready && bnet_ddr_sample_valid),
  .axi_sys        (axi2_sys),
  .sample_o       (bnet_ddr_sample_dat),
  .valid_o        (bnet_ddr_sample_valid),
  .ready_o        (),
  .read_ptr_o     (bnet_ddr_sample_rptr),
  .underrun_o     (bnet_ddr_sample_underrun),
  .debug0_o       (bnet_ddr_sample_debug0),
  .debug1_o       (bnet_ddr_sample_debug1)
);

bnet_axi_reader_ch #(
  .SAMPLE_DW (14)
) i_bnet_weight_reader (
  .cfg_clk_i      (adc_clk),
  .cfg_rstn_i     (adc_rstn),
  .soft_reset_i   (bnet_soft_reset_pulse),
  .start_i        (bnet_start_run && (bnet_input_sel == 2'd2) && bnet_weight_stream_active),
  .enable_i       (bnet_stream_enable[1]),
  .active_buf_i   (bnet_stream_active_buf[1]),
  .base0_i        (bnet_stream_base0[1]),
  .base1_i        (bnet_stream_base1[1]),
  .length_bytes_i (bnet_stream_length[1]),
  .stride_bytes_i (bnet_stream_stride[1]),
  .consume_i      ((bnet_input_sel == 2'd2) && bnet_weight_stream_active &&
                   bnet_weight_ready && bnet_ddr_weight_valid),
  .axi_sys        (axi3_sys),
  .sample_o       (bnet_ddr_weight_dat),
  .valid_o        (bnet_ddr_weight_valid),
  .ready_o        (),
  .read_ptr_o     (bnet_ddr_weight_rptr),
  .underrun_o     (bnet_ddr_weight_underrun),
  .debug0_o       (bnet_ddr_weight_debug0),
  .debug1_o       (bnet_ddr_weight_debug1)
);

// Select the butterfly input source.
//   0: ASG test stream. ASG A carries samples and ASG B carries packed weights.
//   1: ADC real-time stream. ADC A carries samples; ASG B still carries packed
//      weights until the dedicated weight/DDR reader is wired in.
//   2: reserved for the upcoming DDR-backed BNET stream reader.
always_comb begin
  bnet_sample_dat = asg_dat[0];
  bnet_weight_dat = asg_dat[1];
  bnet_start = trig_asg_out;
  bnet_sample_valid = 1'b1;
  bnet_weight_valid = 1'b1;

  unique case (bnet_input_sel)
    2'd1: begin
      bnet_sample_dat = adc_dat[0][14-1:0];
      bnet_weight_dat = asg_dat[1];
    end
    2'd2: begin
      bnet_sample_dat = bnet_ddr_sample_dat;
      bnet_weight_dat = bnet_ddr_weight_dat;
      bnet_start = bnet_start_run;
      bnet_sample_valid = bnet_ddr_sample_valid;
      bnet_weight_valid = bnet_ddr_weight_valid;
    end
    default: begin
      bnet_sample_dat = asg_dat[0];
      bnet_weight_dat = asg_dat[1];
    end
  endcase
end

// Butterfly-network milestone:
// Capture the selected input vector and full per-stage weight stream into local
// RAM, then run all fixed-point butterfly stages from RAM bank to RAM bank. The
// completed vector is played back to the DAC two samples at a time.
butterfly_network #(
  .IN_DW       (14),
  .OUT_DW      (14),
  .WEIGHT_DW   (7),
  .WEIGHT_FRAC (6),
  .VECTOR_LEN  (BNET_SERIAL_VECTOR_LEN)
) i_butterfly_network (
  .clk_i    (adc_clk),
  .rstn_i   (adc_rstn),
  .soft_reset_i (bnet_soft_reset_pulse),
  .start_i  (bnet_start),
  .sample_valid_i (!bnet_static_pipeline_active && bnet_sample_valid),
  .sample_ready_o (bnet_serial_sample_ready),
  .sample_i (bnet_sample_dat),
  .reuse_weights_i (bnet_static_weight_reuse),
  .weight_valid_i (!bnet_static_pipeline_active && bnet_weight_valid),
  .weight_ready_o (bnet_serial_weight_ready),
  .weight_i (bnet_weight_dat),
  .y0_o     (bnet_serial_dat[0]),
  .y1_o     (bnet_serial_dat[1]),
  .output_valid_o (bnet_serial_output_valid),
  .output_ready_i (bnet_serial_output_ready),
  .busy_o   (bnet_serial_busy),
  .done_o   (bnet_serial_done),
  .timing_total_cycles_o (bnet_serial_time_total_cycles),
  .timing_load_cycles_o (bnet_serial_time_load_cycles),
  .timing_compute_cycles_o (bnet_serial_time_compute_cycles),
  .timing_playback_cycles_o (bnet_serial_time_playback_cycles)
);

// Fixed-weight frame-pipeline draft. This path preloads static weights from
// stream 1, then accepts input frames from stream 0. It is selected by CONFIG[5].
butterfly_network_static_pipeline #(
  .IN_DW       (14),
  .OUT_DW      (14),
  .WEIGHT_DW   (7),
  .WEIGHT_FRAC (6),
  .VECTOR_LEN  (BNET_PIPE_VECTOR_LEN)
) i_butterfly_static_pipeline (
  .clk_i    (adc_clk),
  .rstn_i   (adc_rstn),
  .soft_reset_i (bnet_soft_reset_pulse),
  .weight_load_valid_i (bnet_static_pipeline_active && bnet_weight_valid),
  .weight_load_ready_o (bnet_pipe_weight_ready),
  .weight_load_i (bnet_weight_dat),
  .weight_load_done_o (bnet_pipe_weight_done),
  .sample_valid_i (bnet_static_pipeline_active && bnet_sample_valid),
  .sample_ready_o (bnet_pipe_sample_ready),
  .sample_i (bnet_sample_dat),
  .y0_o (bnet_pipe_dat[0]),
  .y1_o (bnet_pipe_dat[1]),
  .output_valid_o (bnet_pipe_output_valid),
  .output_ready_i (bnet_pipe_output_ready),
  .busy_o (bnet_pipe_busy),
  .done_o (bnet_pipe_done),
  .timing_total_cycles_o (bnet_pipe_time_total_cycles),
  .timing_weight_load_cycles_o (bnet_pipe_time_weight_load_cycles),
  .timing_input_load_cycles_o (bnet_pipe_time_input_load_cycles),
  .timing_latency_cycles_o (bnet_pipe_time_latency_cycles),
  .timing_output_cycles_o (bnet_pipe_time_output_cycles)
);

// Optional single-DAC output mode. The BNET engines naturally produce two
// neighboring output samples per clock. CONFIG[6] serializes those two lanes
// onto DAC A over two clocks and drives DAC B to zero. The output_ready
// backpressure above prevents the engines from advancing while the saved odd
// lane sample is being emitted.
always_ff @(posedge adc_clk) begin
  if (!adc_rstn || bnet_soft_reset_pulse) begin
    bnet_dac_dat[0] <= '0;
    bnet_dac_dat[1] <= '0;
    bnet_single_dac_hold <= '0;
    bnet_single_dac_hold_valid <= 1'b0;
  end else if (bnet_single_dac_output_en) begin
    if (bnet_single_dac_hold_valid) begin
      bnet_dac_dat[0] <= bnet_single_dac_hold;
      bnet_dac_dat[1] <= '0;
      bnet_single_dac_hold_valid <= 1'b0;
    end else if (bnet_output_valid) begin
      bnet_dac_dat[0] <= butterfly_dat[0];
      bnet_dac_dat[1] <= '0;
      bnet_single_dac_hold <= butterfly_dat[1];
      bnet_single_dac_hold_valid <= 1'b1;
    end
  end else begin
    bnet_dac_dat[0] <= butterfly_dat[0];
    bnet_dac_dat[1] <= butterfly_dat[1];
    bnet_single_dac_hold_valid <= 1'b0;
  end
end

// Sign-extend the 14-bit butterfly outputs to the existing 15-bit saturation
// stage. Keeping the saturation stage in place preserves the original DAC path
// structure and makes later experiments easier.
assign dac_a_sum = {bnet_dac_dat[0][14-1], bnet_dac_dat[0]};
assign dac_b_sum = {bnet_dac_dat[1][14-1], bnet_dac_dat[1]};

// Saturation limits overflow to the maximum/minimum 14-bit signed value instead
// of wrapping around. Wrapping would turn a too-large positive value into a
// negative value, which is usually disastrous for an analog output.
//
// (^dac_a_sum[14:13]) is an XOR-reduction of the top two bits. In a correctly
// sign-extended signed number, those two bits should match. If they differ, the
// 15-bit sum cannot be represented safely in 14 bits, so this creates a clipped
// full-scale positive or negative value.
assign dac_a = (^dac_a_sum[15-1:15-2]) ? {dac_a_sum[15-1], {13{~dac_a_sum[15-1]}}} : dac_a_sum[14-1:0];
assign dac_b = (^dac_b_sum[15-1:15-2]) ? {dac_b_sum[15-1], {13{~dac_b_sum[15-1]}}} : dac_b_sum[14-1:0];

// Register the DAC output data in the DAC clock domain and convert from signed
// two's-complement into the physical DAC's expected negative-slope format.
//
// digital_loop[1] provides the opposite loopback of digital_loop[0]:
//   digital_loop[1] == 1: send ADC samples directly to DAC
//   digital_loop[1] == 0: send the butterfly-network result
always @(posedge dac_clk_1x)
begin // Loopback is for demonstration only. We avoid constraining for timing optimizations.
  dac_dat_a <= digital_loop[1] ? {adc_dat[0][ADW-1], ~adc_dat[0][ADW-2 -: 13]} : {dac_a[14-1], ~dac_a[14-2:0]};
  dac_dat_b <= digital_loop[1] ? {adc_dat[1][ADW-1], ~adc_dat[1][ADW-2 -: 13]} : {dac_b[14-1], ~dac_b[14-2:0]};
end

// DDR outputs to the external DAC.
//
// The DAC interface multiplexes channels A and B on the same 14 data pins.
// oddr_dac_dat drives channel B on one clock edge and channel A on the other.
// oddr_dac_sel toggles so the external DAC knows which half-cycle belongs to
// which channel. oddr_dac_wrt and oddr_dac_clk provide the DAC timing strobes.
ODDR oddr_dac_clk          (.Q(dac_clk_o), .D1(1'b0     ), .D2(1'b1     ), .C(dac_clk_2p), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_wrt          (.Q(dac_wrt_o), .D1(1'b0     ), .D2(1'b1     ), .C(dac_clk_2x), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_sel          (.Q(dac_sel_o), .D1(1'b1     ), .D2(1'b0     ), .C(dac_clk_1x), .CE(1'b1), .R(dac_rst), .S(1'b0));
ODDR oddr_dac_rst          (.Q(dac_rst_o), .D1(dac_rst  ), .D2(dac_rst  ), .C(dac_clk_1x), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_dat [14-1:0] (.Q(dac_dat_o), .D1(dac_dat_b), .D2(dac_dat_a), .C(dac_clk_1x), .CE(1'b1), .R(dac_rst), .S(1'b0));

////////////////////////////////////////////////////////////////////////////////
//  House Keeping
////////////////////////////////////////////////////////////////////////////////

// The expansion connector pins are bidirectional, so each pin needs three
// internal signals:
// - *_in:  value currently read from the physical pin
// - *_out: value to drive onto the physical pin
// - *_dir: direction control, where 1 means output-enable
//
// The *_alt signals let special functions such as trigger output or CAN take
// over selected expansion pins from the normal software-controlled GPIO path.
logic [DWE-1: 0] exp_p_in ,  exp_n_in ;
logic [DWE-1: 0] exp_p_out,  exp_n_out;
logic [DWE-1: 0] exp_p_dir,  exp_n_dir;
logic [DWE-1: 0] exp_p_otr,  exp_n_otr;
logic [DWE-1: 0] exp_p_dtr,  exp_n_dtr;
logic [DWE-1: 0] exp_p_alt,  exp_n_alt;
logic [DWE-1: 0] exp_p_altr, exp_n_altr;
logic [DWE-1: 0] exp_p_altd, exp_n_altd;

logic [8-1:0] led_hk;
logic [26-1:0] fpga_marker_cnt;
logic [8-1:0] bnet_led_debug;
logic         bnet_led_debug_en;
logic         bnet_led6_heartbeat_en;

// Housekeeping contains low-rate control/status registers: LEDs, GPIO direction
// and output data, digital loopback modes, daisy-chain mode bits, and CAN enable.
// Software accesses these registers through sys[0].
red_pitaya_hk #(.DWE(DWE)) i_hk (
  // system signals
  .clk_i           (adc_clk    ),  // clock
  .rstn_i          (adc_rstn   ),  // reset - active low
  .fclk_i          (fclk[0]    ),  // clock
  .frstn_i         (frstn[0]   ),  // reset - active low

  // LED
  .led_o           (  led_hk   ),  // LED output
  // global configuration
  .digital_loop    (digital_loop),
  .daisy_mode_o    (daisy_mode),
  // Expansion connector
  .exp_p_dat_i     (exp_p_in ),  // input data
  .exp_p_dat_o     (exp_p_out),  // output data
  .exp_p_dir_o     (exp_p_dir),  // 1-output enable
  .exp_n_dat_i     (exp_n_in ),
  .exp_n_dat_o     (exp_n_out),
  .exp_n_dir_o     (exp_n_dir),
  .can_on_o        (can_on   ),
   // System bus
  .sys_addr        (sys[0].addr ),
  .sys_wdata       (sys[0].wdata),
  .sys_wen         (sys[0].wen  ),
  .sys_ren         (sys[0].ren  ),
  .sys_rdata       (sys[0].rdata),
  .sys_err         (sys[0].err  ),
  .sys_ack         (sys[0].ack  )
);


////////////////////////////////////////////////////////////////////////////////
// LED
////////////////////////////////////////////////////////////////////////////////

// LED[7] is a simple FPGA heartbeat. The counter increments at adc_clk. Using a
// high counter bit makes the LED blink slowly enough to see, proving that the
// FPGA clock and reset are alive.
always_ff @(posedge adc_clk) begin
    if (!adc_rstn)
        fpga_marker_cnt <= '0;
    else
        fpga_marker_cnt <= fpga_marker_cnt + 1'b1;
end

// By default LEDs 0..5 still come from housekeeping and LED 7 is a heartbeat.
// BNET_CONTROL[3] enables a visible heartbeat on LED6; clearing it drives LED6
// low. When BNET_CONTROL[2] is set, the BNET register block drives all LED bits
// with CH0[7:0] so direct ARM-to-FPGA register writes are visible on the board.
assign led_o = bnet_led_debug_en ? bnet_led_debug
                                : {fpga_marker_cnt[25],
                                   bnet_led6_heartbeat_en ? fpga_marker_cnt[25] : 1'b0,
                                   led_hk[5:0]};

////////////////////////////////////////////////////////////////////////////////
// GPIO
////////////////////////////////////////////////////////////////////////////////

// Select what signal should be sent out when the trigger-output alternate
// function is enabled:
// - daisy_mode[2] == 1: output the ASG trigger
// - daisy_mode[2] == 0: output the scope trigger
assign trig_output_sel = daisy_mode[2] ? trig_asg_out : scope_trigo;

// Alternate-function selector values. A 1 in exp_*_alt means the pin is driven
// by a special internal function instead of normal GPIO.
assign exp_p_alt  = {DWE{1'b0}};

// On exp_n pins, selected high bits can become CAN or trigger/daisy pins. The
// {{DWE-8{1'b0}}, ...} form pads the vector so the same source works for boards
// with more than 8 expansion pins.
assign exp_n_alt  = {{DWE-8{1'b0}},  can_on,  can_on, 5'h0, daisy_mode[1]  };

// Alternate-function output data. When exp_n_alt for a pin is 1, this value is
// driven instead of exp_n_out from the housekeeping GPIO registers.
assign exp_p_altr = {DWE{1'b0}};
assign exp_n_altr = {{DWE-8{1'b0}}, CAN0_tx, CAN1_tx, 5'h0, trig_output_sel};

// Alternate-function direction control. 1 means "drive this pin as an output".
// CAN TX and trigger output are driven by the FPGA, so their direction bits are
// set to 1 when the corresponding alternate function is selected.
assign exp_p_altd = {DWE{1'b0}};
assign exp_n_altd = {{DWE-8{1'b0}},   1'b1,   1'b1, 5'h0, 1'b1};

// For each expansion pin, choose either the normal GPIO data/direction or the
// alternate-function data/direction. generate-for creates repeated hardware,
// not a software loop; the synthesizer expands this into DWE copies.
genvar GM;
generate
for(GM = 0 ; GM < DWE ; GM = GM + 1) begin : gpios
  assign exp_p_otr[GM] = exp_p_alt[GM] ? exp_p_altr[GM] : exp_p_out[GM];
  assign exp_n_otr[GM] = exp_n_alt[GM] ? exp_n_altr[GM] : exp_n_out[GM];

  assign exp_p_dtr[GM] = exp_p_alt[GM] ? exp_p_altd[GM] : exp_p_dir[GM];
  assign exp_n_dtr[GM] = exp_n_alt[GM] ? exp_n_altd[GM] : exp_n_dir[GM];
end
endgenerate

// IOBUF is a bidirectional pin buffer. T is tri-state control:
// - T = 1: output driver is disabled, pin acts as an input
// - T = 0: output driver is enabled, pin is driven by I
// Since exp_*_dtr uses 1 for output-enable, this code passes ~exp_*_dtr to T.
IOBUF i_iobufp [DWE-1:0] (.O(exp_p_in), .IO(exp_p_io), .I(exp_p_otr), .T(~exp_p_dtr) );
IOBUF i_iobufn [DWE-1:0] (.O(exp_n_in), .IO(exp_n_io), .I(exp_n_otr), .T(~exp_n_dtr) );

// Pack the physical expansion connector inputs into the wider PS GPIO input
// bus. gpio.i[0 +: GDW] is unused in this file; p and n banks occupy the next
// two GDW-wide slices.
assign gpio.i[2*GDW-1:  GDW] = exp_p_in[GDW-1:0];
assign gpio.i[3*GDW-1:2*GDW] = exp_n_in[GDW-1:0];

// CAN RX is only allowed through when the housekeeping block enables CAN.
assign CAN0_rx = can_on & exp_p_in[7];
assign CAN1_rx = can_on & exp_p_in[6];

////////////////////////////////////////////////////////////////////////////////
// oscilloscope
////////////////////////////////////////////////////////////////////////////////

// This design only instantiates a 2-channel scope, but rp_scope_com supports
// multi-channel trigger/status wiring. The *_2_3 signals are tied off because
// channels 2 and 3 do not exist in this build.
wire [ 4-1:0] trig_ch_0_1;
wire [ 4-1:0] trig_ch_2_3 = 4'h0;
wire [16-1:0] trg_state_ch_0_1;
wire [16-1:0] trg_state_ch_2_3 = 16'h0;
wire [16-1:0] adc_state_ch_0_1;
wire [16-1:0] adc_state_ch_2_3 = 16'h0;
wire [16-1:0] axi_state_ch_0_1;
wire [16-1:0] axi_state_ch_2_3 = 16'h0;

// Scope block: captures adc_dat samples into DDR memory using AXI write ports.
// Software configures capture length, trigger source, decimation, etc. through
// sys[1]. The captured data path is high bandwidth, so it uses AXI masters
// axi0_sys/axi1_sys instead of the low-speed system bus.
rp_scope_com #(
  .CHN(0),
  .N_CH(2),
  .DW(14),
  .RSZ(14)) 
  i_scope (
  // ADC
  .adc_dat_i     ({adc_dat[1], adc_dat[0]}  ),
  .adc_clk_i     ({2{adc_clk}}  ),  // clock
  .adc_rstn_i    ({2{adc_rstn}} ),  // reset - active low
  .trig_ext_i    (trig_ext    ),  // external trigger
  .trig_asg_i    (trig_asg_out),  // ASG trigger
  .trig_ch_o     (trig_ch_0_1 ),  // output trigger to ADC for other 2 channels
  .trig_ch_i     (trig_ch_2_3 ),  // input ADC trigger from other 2 channels
  .trig_ext_asg_o(trig_ext_asg01),
  .trig_ext_asg_i(trig_ext_asg01),
  .daisy_trig_o  (scope_trigo ),
  .adc_state_o   (adc_state_ch_0_1),
  .adc_state_i   (adc_state_ch_2_3),
  .axi_state_o   (axi_state_ch_0_1),
  .axi_state_i   (axi_state_ch_2_3),
  .trg_state_o   (trg_state_ch_0_1),
  .trg_state_i   (trg_state_ch_2_3),
  // AXI write channels. The concatenations pack channel 1 and channel 0 AXI
  // signals into the vector format expected by rp_scope_com.
  // AXI0 master                 // AXI1 master
  .axi_waddr_o  ({axi1_sys.waddr,  axi0_sys.waddr} ),
  .axi_wdata_o  ({axi1_sys.wdata,  axi0_sys.wdata} ),
  .axi_wsel_o   ({axi1_sys.wsel,   axi0_sys.wsel}  ),
  .axi_wvalid_o ({axi1_sys.wvalid, axi0_sys.wvalid}),
  .axi_wlen_o   ({axi1_sys.wlen,   axi0_sys.wlen}  ),
  .axi_wfixed_o ({axi1_sys.wfixed, axi0_sys.wfixed}),
  .axi_werr_i   ({axi1_sys.werr,   axi0_sys.werr}  ),
  .axi_wrdy_i   ({axi1_sys.wrdy,   axi0_sys.wrdy}  ),
  // System bus
  .sys_addr      (sys[1].addr ),
  .sys_wdata     (sys[1].wdata),
  .sys_wen       (sys[1].wen  ),
  .sys_ren       (sys[1].ren  ),
  .sys_rdata     (sys[1].rdata),
  .sys_err       (sys[1].err  ),
  .sys_ack       (sys[1].ack  )
);
/*
// Older/alternate scope instance kept here as reference. It is inside a block
// comment, so it is ignored by synthesis and simulation.
red_pitaya_scope (
i_scope (
  // ADC
  .adc_a_i       (adc_dat[0]  ),  // CH 1
  .adc_b_i       (adc_dat[1]  ),  // CH 2
  .adc_clk_i     (adc_clk     ),  // clock
  .adc_rstn_i    (adc_rstn    ),  // reset - active low
  .trig_ext_i    (trig_ext    ),  // external trigger
  .trig_asg_i    (trig_asg_out),  // ASG trigger
  .trig_ext_asg_o(trig_ext_asg01),
  .trig_ext_asg_i(trig_ext_asg01),
  .daisy_trig_o  (scope_trigo ),
  // AXI0 master                 // AXI1 master
  .axi0_waddr_o  (axi0_sys.waddr ),  .axi1_waddr_o  (axi1_sys.waddr ),
  .axi0_wdata_o  (axi0_sys.wdata ),  .axi1_wdata_o  (axi1_sys.wdata ),
  .axi0_wsel_o   (axi0_sys.wsel  ),  .axi1_wsel_o   (axi1_sys.wsel  ),
  .axi0_wvalid_o (axi0_sys.wvalid),  .axi1_wvalid_o (axi1_sys.wvalid),
  .axi0_wlen_o   (axi0_sys.wlen  ),  .axi1_wlen_o   (axi1_sys.wlen  ),
  .axi0_wfixed_o (axi0_sys.wfixed),  .axi1_wfixed_o (axi1_sys.wfixed),
  .axi0_werr_i   (axi0_sys.werr  ),  .axi1_werr_i   (axi1_sys.werr  ),
  .axi0_wrdy_i   (axi0_sys.wrdy  ),  .axi1_wrdy_i   (axi1_sys.wrdy  ),
  // System bus
  .sys_addr      (sys[1].addr ),
  .sys_wdata     (sys[1].wdata),
  .sys_wen       (sys[1].wen  ),
  .sys_ren       (sys[1].ren  ),
  .sys_rdata     (sys[1].rdata),
  .sys_err       (sys[1].err  ),
  .sys_ack       (sys[1].ack  )
);
*/
////////////////////////////////////////////////////////////////////////////////
//  DAC arbitrary signal generator
////////////////////////////////////////////////////////////////////////////////

// ASG = Arbitrary Signal Generator. It reads waveform data from DDR through its
// AXI interfaces and outputs one signed sample per channel on every dac/adc
// clock tick. For this butterfly milestone, channel A carries input samples and
// channel B carries two packed 7-bit weights per input sample.
red_pitaya_asg i_asg (
   // DAC
  .dac_a_o         (asg_dat[0]  ),  // CH 1
  .dac_b_o         (asg_dat[1]  ),  // CH 2
  .dac_clk_i       (adc_clk     ),  // clock
  .dac_rstn_i      (adc_rstn    ),  // reset - active low
  .trig_a_i        (trig_ext    ),
  .trig_b_i        (trig_ext    ),
  // trig_out_o can be routed back into the scope or out to GPIO/daisy logic.
  .trig_out_o      (trig_asg_out),

  // Normal ASG table mode uses local BRAM. The real DDR HP ports are reserved
  // for BNET in this build, so ASG deep-memory AXI is intentionally stubbed.
  .axi_a_sys       (asg_axi_a_dummy),
  .axi_b_sys       (asg_axi_b_dummy),
  // System bus
  .sys_addr        (sys[2].addr ),
  .sys_wdata       (sys[2].wdata),
  .sys_wen         (sys[2].wen  ),
  .sys_ren         (sys[2].ren  ),
  .sys_rdata       (sys[2].rdata),
  .sys_err         (sys[2].err  ),
  .sys_ack         (sys[2].ack  )
);

////////////////////////////////////////////////////////////////////////////////
//  MIMO PID controller
////////////////////////////////////////////////////////////////////////////////

// PID = proportional-integral-derivative controller. "MIMO" here means the
// block can use multiple inputs/outputs internally. From this top-level view, it
// takes the two ADC channels and produces two signed correction signals. For
// this first butterfly milestone, those correction signals are preserved for
// future use but bypassed by the DAC IO section. Software configures gains and
// setpoints through sys[3].
red_pitaya_pid i_pid (
   // signals
  .clk_i           (adc_clk   ),  // clock
  .rstn_i          (adc_rstn  ),  // reset - active low
  .dat_a_i         (adc_dat[0]),  // in 1
  .dat_b_i         (adc_dat[1]),  // in 2
  .dat_a_o         (pid_dat[0]),  // out 1
  .dat_b_o         (pid_dat[1]),  // out 2
  // System bus
  .sys_addr        (sys[3].addr ),
  .sys_wdata       (sys[3].wdata),
  .sys_wen         (sys[3].wen  ),
  .sys_ren         (sys[3].ren  ),
  .sys_rdata       (sys[3].rdata),
  .sys_err         (sys[3].err  ),
  .sys_ack         (sys[3].ack  )
);

////////////////////////////////////////////////////////////////////////////////
// Daisy test code
////////////////////////////////////////////////////////////////////////////////

// Daisy-chain logic uses the SATA-style connector as a fast serial link between
// Red Pitaya boards. This section is partly test/demo logic: when not in sync
// mode it transmits a fixed word (16'h1234) whenever the receiver is ready.
wire daisy_rx_rdy ;
wire dly_clk = fclk[3]; // 200MHz clock from PS - used for IDELAY (optionaly)

// In daisy sync mode, transmit a replicated trigger-output bit. Otherwise,
// transmit a recognizable test pattern. par_dvi is the transmit data-valid flag;
// it is disabled in sync mode and follows receiver-ready in test mode.
wire [16-1:0] par_dati = daisy_mode[0] ? {16{trig_output_sel}} : 16'h1234;
wire          par_dvi  = daisy_mode[0] ? 1'b0 : daisy_rx_rdy;

// Main daisy-chain transceiver connected to the SATA differential pairs.
// It converts between high-speed serial signals on daisy_p/n and a 16-bit
// parallel word interface in the adc_clk domain.
red_pitaya_daisy i_daisy (
   // SATA connector
  .daisy_p_o       (  daisy_p_o                  ),  // line 1 is clock capable
  .daisy_n_o       (  daisy_n_o                  ),
  .daisy_p_i       (  daisy_p_i                  ),  // line 1 is clock capable
  .daisy_n_i       (  daisy_n_i                  ),
   // Data
  .ser_clk_i       (  ser_clk                    ),  // high speed serial
  .dly_clk_i       (  dly_clk                    ),  // delay clock
   // TX
  .par_clk_i       (  adc_clk                    ),  // data paralel clock
  .par_rstn_i      (  adc_rstn                   ),  // reset - active low
  .par_rdy_o       (  daisy_rx_rdy               ),
  .par_dv_i        (  par_dvi                    ),
  .par_dat_i       (  par_dati                   ),
   // RX
  .par_clk_o       ( adc_clk_daisy               ),
  .par_rstn_o      (                             ),
  .par_dv_o        (                             ),
  .par_dat_o       ( par_dat                     ),

  .sync_mode_i     (  daisy_mode[0]              ),
  .debug_o         (/*led_o*/                    ),
   // System bus
  .sys_clk_i       (  adc_clk                    ),  // clock
  .sys_rstn_i      (  adc_rstn                   ),  // reset - active low
  .sys_addr_i      (  sys[5].addr                ),
  .sys_sel_i       (                             ),
  .sys_wdata_i     (  sys[5].wdata               ),
  .sys_wen_i       (  sys[5].wen                 ),
  .sys_ren_i       (  sys[5].ren                 ),
  .sys_rdata_o     (  sys[5].rdata               ),
  .sys_err_o       (  sys[5].err                 ),
  .sys_ack_o       (  sys[5].ack                 )
);

  `ifdef Z20_G2
  // Some Z20_G2 boards have an additional E3 connector that can carry extra
  // LVDS serial lines. This optional instance exposes those lines as another
  // daisy-chain-style link controlled through sys[6].
  // DIO11 is TX clock
  // DIO12 is RX clock
  // exp_e3x_o={DIO11, DIO13, DIO15, DIO17}
  // exp_e3x_i={DIO12, DIO14, DIO16, DIO18}
red_pitaya_daisy  #(
  .IO_STD("LVDS_25"),
  .N_DATS(3)
) i_serlines_add
(
   // SATA connector
  .daisy_p_o       (  exp_e3p_o                  ),  // line 3 is clock capable (SRCC)
  .daisy_n_o       (  exp_e3n_o                  ),
  .daisy_p_i       (  exp_e3p_i                  ),  // line 3 is clock capable (MRCC)
  .daisy_n_i       (  exp_e3n_i                  ),
   // Data
  .ser_clk_i       (  ser_clk                    ),  // high speed serial
  .dly_clk_i       (  dly_clk                    ),  // delay clock
   // TX
  .par_clk_i       (  adc_clk                    ),  // data paralel clock
  .par_rstn_i      (  adc_rstn                   ),  // reset - active low
  //.par_rdy_o       (  daisy_rx_rdy               ),
  //.par_dv_i        (  par_dvi                    ),
  //.par_dat_i       (  par_dati                   ),
   // RX
  //.par_clk_o       ( adc_clk_daisy               ),
  //.par_rstn_o      (                             ),
  //.par_dv_o        (                             ),
  //.par_dat_o       ( par_dat                     ),

  .sync_mode_i     (  1'b0                       ),
  //.debug_o         (/*led_o*/                    ),
   // System bus
  .sys_clk_i       (  adc_clk                    ),  // clock
  .sys_rstn_i      (  adc_rstn                   ),  // reset - active low
  .sys_addr_i      (  sys[6].addr                ),
  .sys_sel_i       (                             ),
  .sys_wdata_i     (  sys[6].wdata               ),
  .sys_wen_i       (  sys[6].wen                 ),
  .sys_ren_i       (  sys[6].ren                 ),
  .sys_rdata_o     (  sys[6].rdata               ),
  .sys_err_o       (  sys[6].err                 ),
  .sys_ack_o       (  sys[6].ack                 )
);
  `else
  // If the optional E3 connector is not present, sys[6] is still connected to a
  // stub so reads/writes to that address range complete cleanly instead of
  // hanging the bus.
  sys_bus_stub sys_bus_stub_6 (sys[6]);
  `endif

  // sys[7] is the custom butterfly-network scalar register block. With SW=20
  // in the interconnect above, this occupies the 0x0070_0000 FPGA bus region
  // relative to the /dev/uio/api map used by Red Pitaya software.
  bnet_regs #(
    .STREAM_COUNT (BNET_STREAM_COUNT)
  ) i_bnet_regs (
    .clk_i          (adc_clk         ),
    .rstn_i         (adc_rstn        ),
    .sys_addr_i     (sys[7].addr     ),
    .sys_wdata_i    (sys[7].wdata    ),
    .sys_wen_i      (sys[7].wen      ),
    .sys_ren_i      (sys[7].ren      ),
    .sys_rdata_o    (sys[7].rdata    ),
    .sys_err_o      (sys[7].err      ),
    .sys_ack_o      (sys[7].ack      ),
    .led_debug_o    (bnet_led_debug  ),
    .led_debug_en_o (bnet_led_debug_en),
    .led6_heartbeat_en_o (bnet_led6_heartbeat_en),
    .input_sel_o    (bnet_input_sel),
    .static_weight_reuse_o (bnet_static_weight_reuse),
    .static_pipeline_en_o (bnet_static_pipeline_en),
    .single_dac_output_en_o (bnet_single_dac_output_en),
    .start_pulse_o  (bnet_start_pulse),
    .soft_reset_pulse_o (bnet_soft_reset_pulse),
    .compute_busy_i (bnet_busy),
    .compute_done_i (bnet_done),
    .compute_output_valid_i (bnet_output_valid),
    .timing_total_cycles_i (bnet_time_total_cycles),
    .timing_load_cycles_i (bnet_time_load_cycles),
    .timing_compute_cycles_i (bnet_time_compute_cycles),
    .timing_playback_cycles_i (bnet_time_playback_cycles),
    .timing_input_load_cycles_i (bnet_time_input_load_cycles),
    .timing_latency_cycles_i (bnet_time_latency_cycles),
    .stream_base0_o (bnet_stream_base0),
    .stream_base1_o (bnet_stream_base1),
    .stream_length_o(bnet_stream_length),
    .stream_stride_o(bnet_stream_stride),
    .stream_format_o(bnet_stream_format),
    .stream_enable_o(bnet_stream_enable),
    .stream_active_buf_o(bnet_stream_active_buf),
    .stream_read_ptr_i(bnet_stream_read_ptr),
    .stream_debug0_i(bnet_stream_debug0),
    .stream_debug1_i(bnet_stream_debug1),
    .stream_runtime_error_i(bnet_stream_runtime_error)
  );

`else
// SCOPE_ONLY build option:
// This stripped-down path keeps the ADC/scope-related minimum IO alive and
// disables most application modules. It is useful for smaller test builds or
// debugging when the full design is not needed.

// Read the external trigger from exp_p_io[0] but never drive that pin.
IOBUF i_iobuf (.O(trig_ext), .IO(exp_p_io[0]), .I(1'b0), .T(1'b1) );

logic [2-1:0] [ADW-1:0] adc_dat_raw;

// Minimal ADC capture path for SCOPE_ONLY. It registers raw ADC input bits and
// converts them to the same signed negative-slope-corrected format used above.
always @(posedge adc_clk) begin
  adc_dat_raw[0] <= adc_dat_i[0][16-1 -: ADW];
  adc_dat_raw[1] <= adc_dat_i[1][16-1 -: ADW];

  adc_dat[0] <= {adc_dat_raw[0][ADW-1], ~adc_dat_raw[0][ADW-2:0]};
  adc_dat[1] <= {adc_dat_raw[1][ADW-1], ~adc_dat_raw[1][ADW-2:0]};
end

//red_pitaya_hk #(.DWE(DWE)) i_hk (
  //// system signals
  //.clk_i           (adc_clk    ),  // clock
  //.rstn_i          (adc_rstn   ),  // reset - active low
  //.fclk_i          (fclk[0]    ),  // clock
  //.frstn_i         (frstn[0]   ),  // reset - active low
  ////// LED
  ////.led_o           (  led_o     ),  // LED output
  ////// global configuration
  ////.digital_loop    (digital_loop),
  ////.daisy_mode_o    (daisy_mode),
  ////// Expansion connector
  //// .exp_p_dat_i     (exp_p_in ),  // input data
  //// .exp_p_dat_o     (exp_p_out),  // output data
  //// .exp_p_dir_o     (exp_p_dir),  // 1-output enable
  //// .exp_n_dat_i     (exp_n_in ),
  //// .exp_n_dat_o     (exp_n_out),
  //// .exp_n_dir_o     (exp_n_dir),
  //// .can_on_o        (can_on   ),
  ////// System bus
  //.sys_addr        (sys[0].addr ),
  //.sys_wdata       (sys[0].wdata),
  //.sys_wen         (sys[0].wen  ),
  //.sys_ren         (sys[0].ren  ),
  //.sys_rdata       (sys[0].rdata),
  //.sys_err         (sys[0].err  ),
  //.sys_ack         (sys[0].ack  )
//);

//red_pitaya_scope i_scope (
  //// ADC
  //.adc_a_i       (adc_dat[0]  ),  // CH 1
  //.adc_b_i       (adc_dat[1]  ),  // CH 2
  //.adc_clk_i     (adc_clk     ),  // clock
  //.adc_rstn_i    (adc_rstn    ),  // reset - active low
  //.trig_ext_i    (trig_ext    ),  // external trigger
  //.trig_asg_i    (1'b0        ),  // ASG trigger
  //.trig_ext_asg_o(trig_ext_asg01),
  //.trig_ext_asg_i(trig_ext_asg01),
  ////.daisy_trig_o  (scope_trigo ),
  //// AXI0 master                 // AXI1 master
  //.axi0_waddr_o  (axi0_sys.waddr ),  .axi1_waddr_o  (axi1_sys.waddr ),
  //.axi0_wdata_o  (axi0_sys.wdata ),  .axi1_wdata_o  (axi1_sys.wdata ),
  //.axi0_wsel_o   (axi0_sys.wsel  ),  .axi1_wsel_o   (axi1_sys.wsel  ),
  //.axi0_wvalid_o (axi0_sys.wvalid),  .axi1_wvalid_o (axi1_sys.wvalid),
  //.axi0_wlen_o   (axi0_sys.wlen  ),  .axi1_wlen_o   (axi1_sys.wlen  ),
  //.axi0_wfixed_o (axi0_sys.wfixed),  .axi1_wfixed_o (axi1_sys.wfixed),
  //.axi0_werr_i   (axi0_sys.werr  ),  .axi1_werr_i   (axi1_sys.werr  ),
  //.axi0_wrdy_i   (axi0_sys.wrdy  ),  .axi1_wrdy_i   (axi1_sys.wrdy  ),
  //// System bus
  //.sys_addr      (sys[1].addr ),
  //.sys_wdata     (sys[1].wdata),
  //.sys_wen       (sys[1].wen  ),
  //.sys_ren       (sys[1].ren  ),
  //.sys_rdata     (sys[1].rdata),
  //.sys_err       (sys[1].err  ),
  //.sys_ack       (sys[1].ack  )
//);

// In SCOPE_ONLY, the normal DAC-producing blocks are not present. The DAC data
// lines are driven with zero while the clock/write/select/reset pins still get
// valid timing signals below.
assign dac_dat_a = 14'h0;
assign dac_dat_b = 14'h0;

// DDR outputs for the DAC pins, same electrical timing style as the full build,
// but with both DAC channels forced to zero.
ODDR oddr_dac_clk          (.Q(dac_clk_o), .D1(1'b0     ), .D2(1'b1     ), .C(dac_clk_2p), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_wrt          (.Q(dac_wrt_o), .D1(1'b0     ), .D2(1'b1     ), .C(dac_clk_2x), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_sel          (.Q(dac_sel_o), .D1(1'b1     ), .D2(1'b0     ), .C(dac_clk_1x), .CE(1'b1), .R(dac_rst), .S(1'b0));
ODDR oddr_dac_rst          (.Q(dac_rst_o), .D1(dac_rst  ), .D2(dac_rst  ), .C(dac_clk_1x), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_dat [14-1:0] (.Q(dac_dat_o), .D1(dac_dat_b), .D2(dac_dat_a), .C(dac_clk_1x), .CE(1'b1), .R(dac_rst), .S(1'b0));

ODDR i_adc_clk_p ( .Q(adc_clk_o[0]), .D1(1'b1), .D2(1'b0), .C(1'b0), .CE(1'b1), .R(1'b0), .S(1'b0));
ODDR i_adc_clk_n ( .Q(adc_clk_o[1]), .D1(1'b0), .D2(1'b1), .C(1'b0), .CE(1'b1), .R(1'b0), .S(1'b0));

// Simple input/output buffers for the daisy-chain pins in SCOPE_ONLY. The
// received clock/data are captured into local wires, while the outputs are held
// low through differential output buffers.
logic rxs_clk, rxs_dat;
IBUFDS #(.IOSTANDARD ("DIFF_HSTL_I_18")) i_IBUFGDS_clk
(
  .I  ( daisy_p_i[1]  ),
  .IB ( daisy_n_i[1]  ),
  .O  ( rxs_clk     )
);

IBUFDS #(.DIFF_TERM ("FALSE"), .IOSTANDARD ("DIFF_HSTL_I_18")) i_IBUFDS_dat
(
  .I  ( daisy_p_i[0]  ),
  .IB ( daisy_n_i[0]  ),
  .O  ( rxs_dat       )
);

OBUFDS #(.IOSTANDARD ("DIFF_HSTL_I_18"), .SLEW ("FAST")) i_OBUF_clk
(
  .O  ( daisy_p_o[1]  ),
  .OB ( daisy_n_o[1]  ),
  .I  ( 1'b0       )
);

OBUFDS #(.IOSTANDARD ("DIFF_HSTL_I_18"), .SLEW ("FAST")) i_OBUF_dat
(
  .O  ( daisy_p_o[0]  ),
  .OB ( daisy_n_o[0]  ),
  .I  ( 1'b0          )
);


assign adc_cdcs_o = 1'b1 ;
assign dac_pwm_o  = 1'b0;

// Stub unused bus regions so software accesses do not stall. This loop creates
// stubs for sys[2] through sys[6]; sys[0]/sys[1] are the only meaningful regions
// in this reduced build.
generate
for (genvar i=2; i<7; i++) begin: for_sys2
  sys_bus_stub sys_bus_stub_2_5 (sys[i]);
end: for_sys2
endgenerate

`endif
endmodule: red_pitaya_top
