`timescale 1ns/1ps
module tb_tdc_pulse_width #(
  parameter bit FULL_SIZE=0
);
  localparam integer TEST_CARRY4=FULL_SIZE ? 128 : 4;
  localparam integer TEST_DEPTH=FULL_SIZE ? 16384 : 8;
  reg bus_clk=0,fast_clk=0,rstn=0;
  always #4 bus_clk=~bus_clk;
  always #2 fast_clk=~fast_clk;
  reg [31:0] addr=0,wdata=0,period=500;
  reg wen=0,ren=0,event_signal=0,marker=0,run=0,input_select=0,conflict=0;
  wire [31:0] rdata;
  wire ack,err,busy;
  integer phase=0,pattern=0,trigger_number=0;
  bit saw_overlap=0;
  always @(posedge fast_clk) if(rstn && dut.capturing && dut.processing) saw_overlap=1;
  real width_value;
  tdc_pulse_width #(.NUM_CARRY4(TEST_CARRY4),.DEPTH(TEST_DEPTH)) dut(
    .bus_clk_i(bus_clk),.fast_clk_i(fast_clk),.rstn_i(rstn),
    .event_i(event_signal),.cycle_start_i(marker),.pulse_period_i(period),
    .input_select_i(input_select),.legacy_conflict_i(conflict),.busy_o(busy),
    .sys_addr_i(addr),.sys_wdata_i(wdata),.sys_wen_i(wen),.sys_ren_i(ren),
    .sys_rdata_o(rdata),.sys_ack_o(ack),.sys_err_o(err));
  always @(negedge fast_clk) begin
    marker=run && phase==0;
    if(run) phase=(phase==249) ? 0 : phase+1; else phase=0;
  end
  always @(posedge fast_clk) if(marker) begin
    trigger_number=trigger_number+1;
    case(pattern)
      0: begin
        case(trigger_number%4)
          0: width_value=102; 1: width_value=246;
          2: width_value=502; 3: width_value=802;
        endcase
        #11; event_signal=1; #(width_value); event_signal=0;
      end
      1: begin end // no response
      2: event_signal=1; // no falling edge, then HIGH at the next cycle
      3: begin #11;event_signal=1;#102;event_signal=0;
               #100;event_signal=1;#102;event_signal=0;end
      4: begin #11;event_signal=1;#0.2;event_signal=0;end
      6: begin #11;event_signal=1;#988;event_signal=0;end // fall at observed boundary
      default: begin end
    endcase
  end
  // With a negligible PCB delay, tap zero can rise in the same sample as the
  // trigger boundary. This exercises the RAM write to the NEXT frame address.
  always @(posedge marker) if(pattern==5) begin
    event_signal=1;#246;event_signal=0;
  end
  task automatic wr(input [7:0] offset,input [31:0] value,input bit bad=0);
    @(negedge bus_clk);addr={24'h407101,offset};wdata=value;wen=1;
    @(posedge bus_clk);#0.01;
    if(!ack || err!==bad) $fatal(1,"Write %h err=%b expected=%b",offset,err,bad);
    @(negedge bus_clk);wen=0;
    @(negedge bus_clk);
  endtask
  task automatic rd(input [7:0] offset,output [31:0] value,input bit bad=0);
    @(negedge bus_clk);addr={24'h407101,offset};ren=1;
    @(posedge bus_clk);#0.01;
    if(!ack || err!==bad) $fatal(1,"Read %h err=%b expected=%b",offset,err,bad);
    value=rdata;
    @(negedge bus_clk);ren=0;
    repeat(4) @(negedge bus_clk);
    if(rdata!==value) $fatal(1,"Read response was not retained after request");
  endtask
  task automatic wait_done(output [31:0] status);
    integer tries;
    status=1;tries=0;
    while(status[0] && tries<1000000) begin rd(8'h08,status);tries=tries+1;end
    if(status[0] || !status[3]) $fatal(1,"Completion timeout status=%h state=%d",status,dut.state);
  endtask
  task automatic arm(input integer count,input integer mode);
    run=0;
    // An already triggered PCB pulse can finish after output has stopped.
    // Let the behavioral PCB complete it before the next burst's first edge.
    #1000;event_signal=0;pattern=mode;trigger_number=0;
    repeat(5) @(negedge fast_clk);
    wr(8'h0c,count);wr(8'h04,1);run=1;
  endtask
  task automatic record_at(input integer index,output [31:0] flags,output [31:0] ps);
    reg [31:0] sequence_value,coarse,raw;
    wr(8'h18,index);
    rd(8'h1c,sequence_value);rd(8'h20,flags);rd(8'h24,coarse);rd(8'h28,raw);rd(8'h34,ps);
    if(sequence_value!=index+1) $fatal(1,"Sequence mismatch %d %d",sequence_value,index);
    if(flags[0] && flags[8] && ps!=coarse*4000) $fatal(1,"Coarse width mismatch");
  endtask
  reg [31:0] status,value,flags,ps;
  integer expected_ps;
  initial begin
    #120;rstn=1;repeat(12) @(negedge bus_clk);
    rd(0,value);if(value!=32'h50574201) $fatal(1,"ID");
    rd(8'h10,value);if(value!=TEST_DEPTH) $fatal(1,"Capacity");
    if(FULL_SIZE) begin
      // Exercise the production compact BRAM and many staging-ring wraps,
      // rather than only the small controller-test configuration.
      wr(8'h0c,TEST_DEPTH+1,1);
      arm(TEST_DEPTH,0);wait_done(status);run=0;
      if(status!=8 || !saw_overlap) $fatal(1,"Full-size online acquisition status=%h overlap=%b",status,saw_overlap);
      rd(8'h14,value);if(value!=TEST_DEPTH) $fatal(1,"Full-size count");
      for(integer i=0;i<TEST_DEPTH;i=i+1) begin
        record_at(i,flags,ps);
        case((i+1)%4)
          0:expected_ps=102000;1:expected_ps=246000;
          2:expected_ps=502000;3:expected_ps=802000;
        endcase
        if(!flags[0]||!flags[8]||ps<expected_ps-4000||ps>expected_ps+4000)
          $fatal(1,"Full-size RAM record %d flags=%h ps=%d expected=%d",i,flags,ps,expected_ps);
      end
      wr(8'h18,TEST_DEPTH,1);
      $display("tb_tdc_pulse_width: PASS (production 512-tap/16384-record RAM dimensions, online encoding, all record addresses; ideal delays)");
      $finish;
    end
    wr(8'h0c,0,1);wr(8'h0c,9,1);wr(8'h40,2,1);
    conflict=1;wr(8'h04,1,1);conflict=0;
    // Capture all eight frames, including widths shorter than encoder latency.
    arm(8,0);
    wr(8'h0c,2,1);wr(8'h38,0,1);wr(8'h04,4,1);rd(8'h1c,value,1);
    wait_done(status);run=0;
    rd(8'h14,value);if(value!=8) $fatal(1,"Full burst lost frames");
    repeat(100) @(negedge bus_clk); // results must survive delayed readout
    for(integer i=0;i<8;i=i+1) begin
      record_at(i,flags,ps);
      if(!flags[0] || !flags[8]) $fatal(1,"Uncalibrated result flags %h",flags);
      case((i+1)%4)
        0:expected_ps=102000;1:expected_ps=246000;
        2:expected_ps=502000;3:expected_ps=802000;
      endcase
      if(ps<expected_ps-4000 || ps>expected_ps+4000) $fatal(1,"Wrong pulse width %d vs %d",ps,expected_ps);
    end
    // Upload known ideal-model LUTs. Real hardware needs measured tables.
    for(integer i=0;i<32;i=i+1) begin
      wr(8'h38,i);wr(8'h3c,(i%16)*500);
    end
    wr(8'h40,2);arm(4,0);wait_done(status);run=0;
    for(integer i=0;i<4;i=i+1) begin
      record_at(i,flags,ps);
      case((i+1)%4)
        0:expected_ps=102000;1:expected_ps=246000;
        2:expected_ps=502000;3:expected_ps=802000;
      endcase
      if(!flags[0] || !flags[9] || flags[8]) $fatal(1,"Calibrated flags %h",flags);
      if(ps<expected_ps-1000 || ps>expected_ps+1000) $fatal(1,"Fine correction %d vs %d",ps,expected_ps);
    end
    input_select=1;repeat(3) @(negedge bus_clk);
    rd(8'h40,value);if(value[0]||value[2]) $fatal(1,"Source change retained calibration");
    arm(2,1);wait_done(status);run=0;
    record_at(0,flags,ps);if(flags[0]||!flags[1]||!flags[2]||ps!=0) $fatal(1,"Missing pulse");
    arm(2,2);wait_done(status);run=0;event_signal=0;
    record_at(0,flags,ps);if(flags[0]||!flags[2]||!flags[11]) $fatal(1,"Missing fall/saturation");
    record_at(1,flags,ps);if(flags[0]||!flags[3]) $fatal(1,"HIGH at cycle start");
    arm(2,3);wait_done(status);run=0;
    record_at(0,flags,ps);if(flags[0]||!flags[4]) $fatal(1,"Extra pulse");
    arm(1,4);wait_done(status);run=0;
    record_at(0,flags,ps);if(flags[0]||!flags[1]) $fatal(1,"Sub-sample pulse reported as valid");
    period=4;arm(2,1);wait_done(status);run=0;
    if(!status[5]) $fatal(1,"High trigger frequency was accepted");
    rd(8'h14,value);if(value!=0) $fatal(1,"Unsafe-rate results exposed");
    period=500;wr(8'h30,300);arm(4,1);run=0;
    wait_done(status);if(!status[4]) $fatal(1,"Stopped trigger watchdog");
    arm(4,1);wait(dut.state==dut.CAPTURE);run=0;
    wait_done(status);if(!status[4]) $fatal(1,"Trigger stopped mid-frame watchdog");
    rd(8'h14,value);if(value!=1) $fatal(1,"Partial frame count");
    record_at(0,flags,ps);if(flags[0]||!flags[5]) $fatal(1,"Partial frame was not marked invalid");
    wr(8'h30,250000);arm(8,0);wr(8'h04,2);wait_done(status);run=0;
    if(!status[6]) $fatal(1,"Capture abort");
    // Abort decoding and immediately re-arm: stale encoder completion must not leak.
    arm(1,0);wait(dut.processing);wr(8'h04,2);wait_done(status);run=0;
    arm(1,0);wait_done(status);run=0;record_at(0,flags,ps);
    if(!flags[0]) $fatal(1,"Abort/rearm corrupted record flags=%h",flags);
    arm(1,0);@(posedge marker);dut.ticks=32'hfffffff0;
    wait_done(status);run=0;record_at(0,flags,ps);
    if(!flags[0]||ps<242000||ps>250000) $fatal(1,"Coarse timestamp wrap");
    arm(8,5);wait_done(status);run=0;
    for(integer i=0;i<8;i=i+1) begin
      record_at(i,flags,ps);
      if(!flags[0]||ps<242000||ps>250000) $fatal(1,"Boundary rise RAM address %d flags=%h ps=%d",i,flags,ps);
    end
    arm(2,6);wait_done(status);run=0;
    record_at(0,flags,ps);
    if(flags[0]||!flags[10]||flags[2]||ps!=0) $fatal(1,"Boundary fall RAM/flags %h",flags);
    // Stall processing deliberately: the raw ring must flag overflow instead
    // of overwriting a frame or returning a plausible but corrupt burst.
    arm(8,0);force dut.encoder_done=0;
    wait_done(status);run=0;release dut.encoder_done;
    if(!status[7]) $fatal(1,"Staging overflow was not reported");
    rd(8'h14,value);if(value!=0) $fatal(1,"Overflow exposed partial results");
    arm(1,0);wait_done(status);run=0;record_at(0,flags,ps);
    if(!flags[0] || status[7]) $fatal(1,"Overflow/rearm failed");
    wr(8'h04,4);while(busy) @(negedge bus_clk);
    rd(8'h14,value);if(value!=0) $fatal(1,"Clear");
    $display("tb_tdc_pulse_width: PASS (online burst, both edges, fine LUT, errors, watchdog, abort, staging overflow, boundary RAM writes, CDC readout; ideal delays)");
    $finish;
  end
  initial begin #100000000; $fatal(1,"Watchdog");end
endmodule
