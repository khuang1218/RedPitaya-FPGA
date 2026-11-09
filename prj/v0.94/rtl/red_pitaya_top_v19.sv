// V19: dual full-feature TDC, two local-table ASGs, pulse, DAC80516 SPI/LDAC.
// Scope/ADC processing, PID, AMS/PWM, BNET and daisy engines are absent.
// PS/MIO, housekeeping and analog sampling clocks remain essential infrastructure.
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


localparam int GDW=DWE;
localparam int RST_MAX=64;
localparam int PULSE_GPIO_INDEX=1;
localparam int TDC_GPIO_INDEX=2;
logic [3:0] fclk,frstn;
logic adc_clk_in,pll_adc_clk,pll_dac_clk_1x,pll_dac_clk_2x,pll_dac_clk_2p;
logic pll_ser_clk,pll_pwm_clk,pll_locked,pll_locked_r;
logic fpll_locked_r,fpll_locked_r2,fpll_locked_r3,rst_after_locked,rstn_pll;
logic [15:0] rst_cnt='0;
logic adc_clk,adc_rstn,dac_clk_1x,dac_clk_2x,dac_clk_2p,dac_axi_clk,dac_axi_rstn;
logic ser_clk,pwm_clk,pwm_rstn,dac_rst;
logic CAN0_rx,CAN0_tx,CAN1_rx,CAN1_tx,can_on;
logic [1:0] digital_loop;
logic [2:0] daisy_mode;
logic trig_ext,trig_asg_out;
logic signed [1:0][13:0] asg_dat;
logic [13:0] dac_dat_a,dac_dat_b;
logic [DWE-1:0] exp_p_in,exp_n_in,exp_p_out,exp_n_out,exp_p_dir,exp_n_dir;
wire [DWE-1:0] exp_p_otr=exp_p_out,exp_p_dtr=exp_p_dir;
logic [7:0] led_hk;
logic [25:0] fpga_marker_cnt;
logic pulse_pin_data,pulse_pin_dir,pulse_cycle_start;
logic [31:0] pulse_active_period,pulse_sys_rdata;
logic pulse_sys_err,pulse_sys_ack,pulse_sys_wen,pulse_sys_ren;
logic spi_clk,spi_mosi,spi_cs_n,spi_ldac_n;
logic [31:0] spi_rdata;
logic spi_ack,spi_err;
logic [1:0][31:0] tdc_rdata;
logic [1:0] tdc_ack,tdc_err;
wire [3:0] region=sys[7].addr[19:16];
wire select_pulse=region==4'h2;
wire select_tdc0=region==4'h1;
wire select_tdc1=region==4'h3;
wire select_spi=region==4'h4;
logic invalid_ack;
sys_bus_if ps_sys (.clk(fclk[0]),.rstn(frstn[0]));
sys_bus_if sys [7:0] (.clk(adc_clk),.rstn(adc_rstn));
gpio_if #(.DW(3*GDW)) gpio ();
axi_sys_if axi0_sys (.clk(adc_clk),.rstn(adc_rstn));
axi_sys_if axi1_sys (.clk(adc_clk),.rstn(adc_rstn));
axi_sys_if axi2_sys (.clk(dac_axi_clk),.rstn(dac_axi_rstn));
axi_sys_if axi3_sys (.clk(dac_axi_clk),.rstn(dac_axi_rstn));
axi_sys_if asg_axi_a_dummy (.clk(dac_axi_clk),.rstn(dac_axi_rstn));
axi_sys_if asg_axi_b_dummy (.clk(dac_axi_clk),.rstn(dac_axi_rstn));
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


assign axi0_sys.waddr='0;
assign axi0_sys.wdata='0;
assign axi0_sys.wsel='0;
assign axi0_sys.wsize='0;
assign axi0_sys.wvalid='0;
assign axi0_sys.wlen='0;
assign axi0_sys.wfixed='0;
assign axi0_sys.raddr='0;
assign axi0_sys.rsel='0;
assign axi0_sys.rsize='0;
assign axi0_sys.rvalid='0;
assign axi0_sys.rlen='0;
assign axi0_sys.rfixed='0;
assign axi0_sys.rrdys='0;
assign axi1_sys.waddr='0;
assign axi1_sys.wdata='0;
assign axi1_sys.wsel='0;
assign axi1_sys.wsize='0;
assign axi1_sys.wvalid='0;
assign axi1_sys.wlen='0;
assign axi1_sys.wfixed='0;
assign axi1_sys.raddr='0;
assign axi1_sys.rsel='0;
assign axi1_sys.rsize='0;
assign axi1_sys.rvalid='0;
assign axi1_sys.rlen='0;
assign axi1_sys.rfixed='0;
assign axi1_sys.rrdys='0;
assign axi2_sys.waddr='0;
assign axi2_sys.wdata='0;
assign axi2_sys.wsel='0;
assign axi2_sys.wsize='0;
assign axi2_sys.wvalid='0;
assign axi2_sys.wlen='0;
assign axi2_sys.wfixed='0;
assign axi2_sys.raddr='0;
assign axi2_sys.rsel='0;
assign axi2_sys.rsize='0;
assign axi2_sys.rvalid='0;
assign axi2_sys.rlen='0;
assign axi2_sys.rfixed='0;
assign axi2_sys.rrdys='0;
assign axi3_sys.waddr='0;
assign axi3_sys.wdata='0;
assign axi3_sys.wsel='0;
assign axi3_sys.wsize='0;
assign axi3_sys.wvalid='0;
assign axi3_sys.wlen='0;
assign axi3_sys.wfixed='0;
assign axi3_sys.raddr='0;
assign axi3_sys.rsel='0;
assign axi3_sys.rsize='0;
assign axi3_sys.rvalid='0;
assign axi3_sys.rlen='0;
assign axi3_sys.rfixed='0;
assign axi3_sys.rrdys='0;
assign asg_axi_a_dummy.werr='0;
assign asg_axi_a_dummy.wrdy='1;
assign asg_axi_a_dummy.rdata='0;
assign asg_axi_a_dummy.rerr='0;
assign asg_axi_a_dummy.rrdym='1;
assign asg_axi_a_dummy.rardy='1;
assign asg_axi_b_dummy.werr='0;
assign asg_axi_b_dummy.wrdy='1;
assign asg_axi_b_dummy.rdata='0;
assign asg_axi_b_dummy.rerr='0;
assign asg_axi_b_dummy.rrdym='1;
assign asg_axi_b_dummy.rardy='1;

assign CAN0_rx=1'b0;
assign CAN1_rx=1'b0;
assign trig_ext=exp_p_in[0];
assign gpio.i[GDW-1:0]='0;
assign gpio.i[2*GDW-1:GDW]=exp_p_in;
assign gpio.i[3*GDW-1:2*GDW]=exp_n_in;
red_pitaya_hk #(.DWE(DWE)) i_hk (
  // system signals
  .clk_i           (adc_clk    ),  // clock
  .rstn_i          (adc_rstn   ),  // reset - active low
  .fclk_i          (fclk[0]    ),  // clock
  .frstn_i         (frstn[0]   ),  // reset - active low

  // LED
  .led_o           (  led_hk   ),  // LED output
  .diag_i          (32'd0),         // no external housekeeping diagnostics
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



always_ff @(posedge adc_clk) begin
 if(!adc_rstn) fpga_marker_cnt<='0;
 else fpga_marker_cnt<=fpga_marker_cnt+1'b1;
end
assign led_o={fpga_marker_cnt[25],led_hk[6:0]};
assign dac_pwm_o='0;
assign adc_clk_o=2'b10;
assign adc_cdcs_o=1'b1;
// Unused differential outputs are driven through proper differential buffers.
OBUFDS #(.IOSTANDARD("DIFF_HSTL_I_18")) daisy_off[1:0](.I(2'b0),.O(daisy_p_o),.OB(daisy_n_o));
OBUFDS #(.IOSTANDARD("LVDS_25")) e3_off[1:0](.I(2'b0),.O(exp_e3p_o[3:2]),.OB(exp_e3n_o[3:2]));
// Dedicated functions always own their pins, independent of housekeeping writes.
for(genvar g=0;g<DWE;g++) begin: gpios
 if(g==1) begin: pulse_pin
  IOBUF i_iobufp(.IO(exp_p_io[g]),.I(pulse_pin_data),.T(~pulse_pin_dir),.O(exp_p_in[g]));
 end else if(g==2 || g==3 || g==6) begin: dedicated_input
  IOBUF i_iobufp(.IO(exp_p_io[g]),.I(1'b0),.T(1'b1),.O(exp_p_in[g]));
 end else if(g==4) begin: spi_clock
  IOBUF i_iobufp(.IO(exp_p_io[g]),.I(spi_clk),.T(1'b0),.O(exp_p_in[g]));
 end else if(g==5) begin: spi_data
  IOBUF i_iobufp(.IO(exp_p_io[g]),.I(spi_mosi),.T(1'b0),.O(exp_p_in[g]));
 end else if(g==7) begin: spi_select
  IOBUF i_iobufp(.IO(exp_p_io[g]),.I(spi_cs_n),.T(1'b0),.O(exp_p_in[g]));
 end else begin: normal_pin
  IOBUF i_iobufp(.IO(exp_p_io[g]),.I(exp_p_out[g]),.T(~exp_p_dir[g]),.O(exp_p_in[g]));
 end
 if(g==4) begin: dac_load
  IOBUF i_iobufn(.IO(exp_n_io[g]),.I(spi_ldac_n),.T(1'b0),.O(exp_n_in[g]));
 end else begin: normal_negative_pin
  IOBUF i_iobufn(.IO(exp_n_io[g]),.I(exp_n_out[g]),.T(~exp_n_dir[g]),.O(exp_n_in[g]));
 end
end
red_pitaya_asg_v19 i_asg (
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


always_ff @(posedge dac_clk_1x) begin
 dac_dat_a<={asg_dat[0][13],~asg_dat[0][12:0]};
 dac_dat_b<={asg_dat[1][13],~asg_dat[1][12:0]};
end
ODDR oddr_dac_clk          (.Q(dac_clk_o), .D1(1'b0     ), .D2(1'b1     ), .C(dac_clk_2p), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_wrt          (.Q(dac_wrt_o), .D1(1'b0     ), .D2(1'b1     ), .C(dac_clk_2x), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_sel          (.Q(dac_sel_o), .D1(1'b1     ), .D2(1'b0     ), .C(dac_clk_1x), .CE(1'b1), .R(dac_rst), .S(1'b0));
ODDR oddr_dac_rst          (.Q(dac_rst_o), .D1(dac_rst  ), .D2(dac_rst  ), .C(dac_clk_1x), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_dat [14-1:0] (.Q(dac_dat_o), .D1(dac_dat_b), .D2(dac_dat_a), .C(dac_clk_1x), .CE(1'b1), .R(dac_rst), .S(1'b0));


// Removed register regions return bus errors instead of silently emulating hardware.
for(genvar slot=1;slot<7;slot++) begin: unused_slots
 if(slot!=2) begin: stub
  always_ff @(posedge adc_clk) begin
   if(!adc_rstn) sys[slot].ack<=0;
   else sys[slot].ack<=sys[slot].wen || sys[slot].ren;
  end
  assign sys[slot].err=sys[slot].ack;
  assign sys[slot].rdata=32'b0;
 end
end

tdc_top #(.VERSION(8'd19),.NUM_CARRY4(128),.FIFO_DEPTH(256),.INVERT_TAPS(1'b0),.RETURN_DIFF_TERM(1'b1)) i_tdc0 (
 .clk_i(adc_clk),.rstn_i(adc_rstn),.test_clk_i(fclk[0]),.test_rstn_i(frstn[0]),
 .fast_clk_i(ser_clk),.pulse_cycle_start_i(pulse_cycle_start),.pulse_period_i(pulse_active_period),
 .launch_p_o(exp_e3p_o[0]),.launch_n_o(exp_e3n_o[0]),
 .return_p_i(exp_e3p_i[0]),.return_n_i(exp_e3n_i[0]),.return_single_i(exp_p_in[2]),
 .sys_addr_i(sys[7].addr),.sys_wdata_i(sys[7].wdata),
 .sys_wen_i(sys[7].wen && select_tdc0),.sys_ren_i(sys[7].ren && select_tdc0),
 .sys_rdata_o(tdc_rdata[0]),.sys_ack_o(tdc_ack[0]),.sys_err_o(tdc_err[0]));

tdc_top #(.VERSION(8'd19),.NUM_CARRY4(128),.FIFO_DEPTH(256),.INVERT_TAPS(1'b0),.RETURN_DIFF_TERM(1'b1)) i_tdc1 (
 .clk_i(adc_clk),.rstn_i(adc_rstn),.test_clk_i(fclk[0]),.test_rstn_i(frstn[0]),
 .fast_clk_i(ser_clk),.pulse_cycle_start_i(pulse_cycle_start),.pulse_period_i(pulse_active_period),
 .launch_p_o(exp_e3p_o[1]),.launch_n_o(exp_e3n_o[1]),
 .return_p_i(exp_e3p_i[1]),.return_n_i(exp_e3n_i[1]),.return_single_i(exp_p_in[3]),
 .sys_addr_i(sys[7].addr),.sys_wdata_i(sys[7].wdata),
 .sys_wen_i(sys[7].wen && select_tdc1),.sys_ren_i(sys[7].ren && select_tdc1),
 .sys_rdata_o(tdc_rdata[1]),.sys_ack_o(tdc_ack[1]),.sys_err_o(tdc_err[1]));

assign pulse_sys_wen=sys[7].wen && select_pulse;
assign pulse_sys_ren=sys[7].ren && select_pulse;
  pulse_gen #(.GPIO_INDEX(PULSE_GPIO_INDEX)) i_pulse_gen (
    .bus_clk_i   (adc_clk),
    .fast_clk_i  (ser_clk),
    .arstn_i     (adc_rstn),
    .sys_addr_i  (sys[7].addr),
    .sys_wdata_i (sys[7].wdata),
    .sys_wen_i   (pulse_sys_wen),
    .sys_ren_i   (pulse_sys_ren),
    .sys_rdata_o (pulse_sys_rdata),
    .sys_err_o   (pulse_sys_err),
    .sys_ack_o   (pulse_sys_ack),
    .gpio_data_i (exp_p_otr[PULSE_GPIO_INDEX]),
    .gpio_dir_i  (exp_p_dtr[PULSE_GPIO_INDEX]),
    .pin_data_o  (pulse_pin_data),
    .pin_dir_o   (pulse_pin_dir),
    .cycle_start_o (pulse_cycle_start),
    .active_period_o (pulse_active_period)
  );


dac80516_spi i_dac_spi(
 .clk_i(adc_clk),.rstn_i(adc_rstn),.miso_i(exp_p_in[6]),
 .sclk_o(spi_clk),.mosi_o(spi_mosi),.cs_n_o(spi_cs_n),.ldac_n_o(spi_ldac_n),
 .sys_addr_i(sys[7].addr),.sys_wdata_i(sys[7].wdata),
 .sys_wen_i(sys[7].wen && select_spi),.sys_ren_i(sys[7].ren && select_spi),
 .sys_rdata_o(spi_rdata),.sys_ack_o(spi_ack),.sys_err_o(spi_err));
always_ff @(posedge adc_clk) begin
 if(!adc_rstn) invalid_ack<=0;
 else invalid_ack<=(sys[7].wen || sys[7].ren) &&
                  !(select_tdc0 || select_tdc1 || select_pulse || select_spi);
end
assign sys[7].rdata=select_tdc0 ? tdc_rdata[0] : select_tdc1 ? tdc_rdata[1] :
                      select_pulse ? pulse_sys_rdata : select_spi ? spi_rdata : 32'b0;
assign sys[7].ack=select_tdc0 ? tdc_ack[0] : select_tdc1 ? tdc_ack[1] :
                      select_pulse ? pulse_sys_ack : select_spi ? spi_ack : invalid_ack;
assign sys[7].err=select_tdc0 ? tdc_err[0] : select_tdc1 ? tdc_err[1] :
                      select_pulse ? pulse_sys_err : select_spi ? spi_err : invalid_ack;
endmodule
