`timescale 1ns/1ps
module tb_v19_dual_width;
  reg bus_clk=0,fast_clk=0,rstn=0,run=0,marker=0;
  always #4 bus_clk=~bus_clk;
  always #2 fast_clk=~fast_clk;
  integer phase=0,hold=2;
  reg [1:0] event_signal=0,wen=0,ren=0;
  reg [1:0][31:0] addr=0,wdata=0;
  wire [1:0][31:0] rdata;
  wire [1:0] ack,err,busy;
  for(genvar i=0;i<2;i++) begin: cores
    tdc_pulse_width #(.NUM_CARRY4(128),.DEPTH(32)) dut(
      .bus_clk_i(bus_clk),.fast_clk_i(fast_clk),.rstn_i(rstn),.event_i(event_signal[i]),
      .cycle_start_i(marker),.pulse_period_i(32'd500),.input_select_i(1'b1),.legacy_conflict_i(1'b0),
      .busy_o(busy[i]),.sys_addr_i(addr[i]),.sys_wdata_i(wdata[i]),.sys_wen_i(wen[i]),.sys_ren_i(ren[i]),
      .sys_rdata_o(rdata[i]),.sys_ack_o(ack[i]),.sys_err_o(err[i]));
  end
  always @(negedge fast_clk) begin
    marker=run && phase==0;
    phase=run ? ((phase==249) ? 0 : phase+1) : 0;
  end
  always @(posedge marker) begin #11;event_signal[0]=1;#96;event_signal[0]=0;end
  always @(posedge marker) begin #27;event_signal[1]=1;#160;event_signal[1]=0;end
  task automatic wr(input integer c,input [7:0] offset,input [31:0] value);
    @(negedge bus_clk);addr[c]=offset;wdata[c]=value;wen[c]=1;
    repeat(hold) begin @(posedge bus_clk);#0.1;if(!ack[c] || err[c]) $fatal(1,"CH%0d write %h",c,offset);end
    @(negedge bus_clk);wen[c]=0;repeat(2) @(negedge bus_clk);
  endtask
  task automatic rd(input integer c,input [7:0] offset,output [31:0] value);
    @(negedge bus_clk);addr[c]=offset;ren[c]=1;
    @(posedge bus_clk);#0.1;if(!ack[c] || err[c]) $fatal(1,"CH%0d read %h",c,offset);value=rdata[c];
    @(negedge bus_clk);ren[c]=0;repeat(16) @(negedge bus_clk);
  endtask
  reg [31:0] value;
  integer c,n;
  initial begin
    if($value$plusargs("BUS_HOLD_CYCLES=%d",hold)) begin end
    repeat(8) @(negedge bus_clk);rstn=1;repeat(20) @(negedge bus_clk);
    wr(0,8'h38,5);wr(0,8'h3c,1234);wr(1,8'h38,5);wr(1,8'h3c,2345);
    rd(0,8'h3c,value);if(value!=1234) $fatal(1,"CH0 LUT isolation");
    rd(1,8'h3c,value);if(value!=2345) $fatal(1,"CH1 LUT isolation");
    wr(0,8'h58,8);wr(1,8'h58,16);
    rd(0,8'h58,value);if(value!=8) $fatal(1,"CH0 frame offset isolation");
    rd(1,8'h58,value);if(value!=16) $fatal(1,"CH1 frame offset isolation");
    wr(0,8'h58,0);wr(1,8'h58,0);
    wr(0,8'h0c,16);wr(1,8'h0c,16);wr(0,8'h04,1);wr(1,8'h04,1);run=1;
    #20000;run=0;#2000;
    for(c=0;c<2;c=c+1) begin
      rd(c,8'h08,value);if(value[0] || !value[3]) $fatal(1,"CH%0d not done: %h",c,value);
      rd(c,8'h14,value);if(value!=16) $fatal(1,"CH%0d count %d",c,value);
      for(n=0;n<16;n=n+1) begin
        wr(c,8'h18,n);rd(c,8'h20,value);if(!value[0]) $fatal(1,"CH%0d invalid record %h",c,value);
        rd(c,8'h34,value);
        if(value!=(c==0 ? 96000 : 160000)) $fatal(1,"CH%0d width=%d",c,value);
      end
    end
    wr(0,8'h04,4);#1000;
    rd(1,8'h14,value);if(value!=16) $fatal(1,"Clearing CH0 destroyed CH1");
    $display("PASS dual TDC: simultaneous 512-tap captures, distinct widths, independent LUT/offset/clear, hold=%0d",hold);$finish;
  end
  initial begin #1000000;$fatal(1,"Dual timeout");end
endmodule
