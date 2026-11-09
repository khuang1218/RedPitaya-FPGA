`timescale 1ns/1ps
// Full-rate initiation, bubbles and in-flight reset against an independent
// whole-vector reference. This checks latency/association as well as codes.
module tb_tdc_encoder_stream #(parameter integer TAPS=512);
  localparam IW=$clog2(TAPS),LATENCY=IW+3;
  // Random full-width vectors are deliberately expensive in event simulation.
  // 128 production-size launches still overlap many tokens and reset in flight;
  // small widths exercise thousands of launches in addition to exhaustive tests.
  localparam CYCLES=(TAPS>=512) ? 128 : 4096;
  reg clk=0,rstn=0,start=0;
  reg [TAPS-1:0] raw=0;
  always #2 clk=~clk;
  wire done;
  wire [IW-1:0] index_value;
  wire [7:0] status;
  tdc_population_pipeline #(.NUM_TAPS(TAPS),.INDEX_W(IW)) dut(
    .clk_i(clk),.rstn_i(rstn),.start_i(start),.raw_taps_i(raw),
    .done_o(done),.fine_index_o(index_value),.status_o(status));
  function automatic [IW+7:0] reference(input reg [TAPS-1:0] sample);
    reg l,r,f,z,m,b,allowed;
    reg [7:0] flags;
    integer pop,leading,last_end;
    begin
      pop=0;leading=0;last_end=0;z=0;m=0;b=0;
      for(integer i=0;i<TAPS;i=i+1) begin
        l=sample[(i==0)?0:i-1];r=sample[(i==TAPS-1)?i:i+1];
        f=(l&sample[i])|(l&r)|(sample[i]&r);
        pop=pop+int'(sample[i]);b=b|(f!=sample[i]);
        if(!f) z=1;
        else begin last_end=i+1;if(z)m=1;else leading=leading+1;end
      end
      allowed=last_end-leading<=8;
      flags=((sample=='0)?8'h0a:0)|((&sample)?8'h12:0)|
        ((m&&!allowed)?8'h04:0)|((b||(m&&allowed))?8'h20:0)|
        ((sample!='0&&!(&sample)&&(!m||allowed))?8'h01:0);
      reference={flags,IW'((pop>=TAPS)?TAPS-1:pop)};
    end
  endfunction
  reg [LATENCY-1:0] expected_valid=0;
  reg [IW+7:0] expected[0:LATENCY-1];
  integer checked=0;
  always @(posedge clk) begin
    if(!rstn) expected_valid<=0;
    else expected_valid<={expected_valid[LATENCY-2:0],start};
    expected[0]<=reference(raw);
    for(integer i=1;i<LATENCY;i=i+1) expected[i]<=expected[i-1];
  end
  always @(negedge clk) begin
    if(done!==expected_valid[LATENCY-1]) $fatal(1,"Stream validity/flush latency mismatch");
    if(done) begin
      if({status,index_value}!==expected[LATENCY-1]) $fatal(1,"Stream code/metadata association mismatch");
      checked=checked+1;
    end
  end
  initial begin
    repeat(4) @(negedge clk);
    for(integer cycle=0;cycle<CYCLES;cycle=cycle+1) begin
      @(negedge clk);#0.01;
      rstn=(cycle%97!=0);start=(cycle%7!=0);
      // Mix clean thresholds, reordered/local bubbles and arbitrary invalid
      // vectors. Several hundred inputs are launched without an idle gap.
      if(cycle%3==0) raw={TAPS{1'b1}}>>(cycle%(TAPS+1));
      else for(integer tap=0;tap<TAPS;tap=tap+1) raw[tap]=1'($urandom);
      if(cycle>8&&cycle<64) start=1;
    end
    @(negedge clk);#0.01;start=0;rstn=1;
    repeat(LATENCY+3) @(negedge clk);
    $display("tb_tdc_encoder_stream: PASS (%0d taps, %0d checked outputs, one-clock initiation, bubbles/reset)",TAPS,checked);
    $finish;
  end
endmodule
