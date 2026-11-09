`timescale 1ns/1ps
module tb_dac80516_spi;
  reg clk=0,rstn=0,miso=0,wen=0,ren=0;
  always #4 clk=~clk;
  reg [31:0] addr=0,wdata=0;
  wire [31:0] rdata;
  wire ack,err,sclk,mosi,cs,ldac;
  integer hold=1,bit_count=0,frames=0,loads=0;
  reg aborting=0;
  reg [23:0] wire_word=0,history[0:255];
  real cs_fall=0,cs_rise=-1000,last_fall=-1000,last_rise=-1000,ldac_fall=0;
  real measured_period=0;
  dac80516_spi #(.STARTUP_CYCLES(30)) dut(
    .clk_i(clk),.rstn_i(rstn),.miso_i(miso),.sclk_o(sclk),.mosi_o(mosi),
    .cs_n_o(cs),.ldac_n_o(ldac),.sys_addr_i(addr),.sys_wdata_i(wdata),
    .sys_wen_i(wen),.sys_ren_i(ren),.sys_rdata_o(rdata),.sys_ack_o(ack),.sys_err_o(err));
  always @(negedge cs) if(rstn) begin
    if($realtime-cs_rise<15) $fatal(1,"CS high interval too short");
    cs_fall=$realtime;bit_count=0;wire_word=0;last_fall=-1000;last_rise=-1000;
  end
  // Device readback changes up to 23 ns after rising SCLK (FSDO=0).
  always @(posedge sclk) if(rstn && !cs) begin
    if(bit_count==0 && $realtime-cs_fall<15) $fatal(1,"CS setup too short");
    if(last_rise>=0) begin
      measured_period=$realtime-last_rise;
      if(measured_period!=8*dut.period_ticks) $fatal(1,"SCLK period mismatch %f",measured_period);
    end
    last_rise=$realtime;
    #23; miso=(24'h00cafe >> (23-bit_count)) & 1;
  end
  always @(negedge sclk) if(rstn && !cs) begin
    if($realtime-last_rise<16) $fatal(1,"SCLK high pulse too short");
    wire_word={wire_word[22:0],mosi};bit_count=bit_count+1;last_fall=$realtime;
  end
  always @(posedge cs) if(rstn && !aborting) begin
    if(bit_count!=24) $fatal(1,"SPI frame clocks=%0d",bit_count);
    if($realtime-last_fall<15) $fatal(1,"CS hold too short");
    history[frames]=wire_word;frames=frames+1;cs_rise=$realtime;
  end
  always @(negedge ldac) if(rstn) begin ldac_fall=$realtime;loads=loads+1;end
  always @(posedge ldac) if(rstn && ldac_fall>0 && !aborting)
    if($realtime-ldac_fall<100) $fatal(1,"LDAC pulse too short");
  task automatic wr(input [7:0] offset,input [31:0] value,input bit bad=0);
    @(negedge clk);addr=offset;wdata=value;wen=1;
    repeat(hold) begin @(posedge clk);#0.1;if(!ack || err!==bad) $fatal(1,"Write %h err=%b expected=%b",offset,err,bad);end
    @(negedge clk);wen=0;repeat(2) @(negedge clk);
  endtask
  task automatic rd(input [7:0] offset,output [31:0] value,input bit bad=0);
    @(negedge clk);addr=offset;ren=1;
    @(posedge clk);#0.1;if(!ack || err!==bad) $fatal(1,"Read error %h",offset);value=rdata;
    @(negedge clk);ren=0;repeat(4) @(negedge clk);
    if(rdata!==value) $fatal(1,"Read response not retained");
  endtask
  task automatic wait_idle;
    integer timeout;reg [31:0] s;
    timeout=0;s=1;
    while(s[0] && timeout<10000) begin rd(8'h08,s);timeout=timeout+1;end
    if(s[0] || !s[5]) $fatal(1,"SPI completion timeout");
  endtask
  reg [31:0] value;
  integer first,n;
  initial begin
    if($value$plusargs("BUS_HOLD_CYCLES=%d",hold)) begin end
    repeat(4) @(negedge clk);rstn=1;
    wr(8'h04,1,1); // startup guard
    repeat(35) @(negedge clk);
    rd(8'h00,value);if(value!=32'h44414301) $fatal(1,"SPI identity");
    wr(8'h04,4,1); // cannot apply an unprepared buffer
    wr(8'h0c,3,1);wr(8'h34,12,1);wr(8'h11,1,1);rd(8'h7c,value,1);
    wr(8'h10,16'h0123);wr(8'h14,16'h4567);wr(8'h18,16'h89ab);wr(8'h1c,16'hcdef);
    wr(8'h0c,5);first=frames;wr(8'h04,1);
    wr(8'h10,16'hffff,1);wr(8'h04,1,1); // reject changes/commands in flight
    wait_idle();
    if(frames!=first+4 || loads!=1) $fatal(1,"Held command repeated or incomplete group");
    if(history[first]!=24'h100123 || history[first+1]!=24'h114567 ||
       history[first+2]!=24'h1289ab || history[first+3]!=24'h13cdef) $fatal(1,"Wire order/channel/data");
    rd(8'h40,value);if(value!=16'h0123) $fatal(1,"Applied snapshot changed");
    wr(8'h10,16'hffff);wr(8'h04,2);wait_idle();
    if(loads!=1) $fatal(1,"LOAD_ONLY changed outputs");
    wr(8'h04,4);wait_idle();if(loads!=2) $fatal(1,"LDAC_ONLY failed");
    rd(8'h40,value);if(value!=16'hffff) $fatal(1,"Apply did not use loaded weights");
    wr(8'h20,24'h090010);first=frames;wr(8'h04,8);wait_idle();
    if(frames!=first+1 || history[first]!=24'h090010 || loads!=2) $fatal(1,"Raw write framing");
    wr(8'h04,4,1); // raw writes invalidate known buffer/configuration state
    wr(8'h20,24'h810000);wr(8'h04,8,1);wr(8'h04,16,1); // read command needs slow clock
    wr(8'h0c,16);first=frames;wr(8'h04,16);wait_idle();
    rd(8'h24,value);
    if(frames!=first+2 || history[first]!=24'h810000 || history[first+1]!=0 || value[15:0]!=16'hcafe)
      $fatal(1,"Readback mismatch %h",value);
    for(n=0;n<3;n=n+1) begin
      case(n) 0:wr(8'h0c,4);1:wr(8'h0c,12);2:wr(8'h0c,250);endcase
      wr(8'h04,1);wait_idle();
    end
    // Reset during a serial access must release both active-low controls.
    wr(8'h04,1);repeat(5) @(negedge clk);aborting=1;rstn=0;
    repeat(4) @(negedge clk);
    if(cs!==1 || ldac!==1 || sclk!==0 || ack!==0) $fatal(1,"Reset did not idle pins");
    $display("PASS SPI: hold=%0d, atomic groups, busy guards, raw read/write, timing, reset",hold);$finish;
  end
  initial begin #2000000;$fatal(1,"Timeout");end
endmodule
