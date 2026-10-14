`timescale 1ns/1ps
module tb_pulse_gen;
  reg bus_clk = 0, fast_clk = 0, fast_run = 1, arstn = 0;
  always #4 bus_clk = ~bus_clk;
  // Deliberately offset the clocks to exercise mailbox synchronization.
  initial begin #0.7; forever begin #2; if (fast_run) fast_clk = ~fast_clk; else fast_clk = 0; end end
  reg [31:0] addr = 0, wdata = 0;
  reg wen = 0, ren = 0, gpio_data = 0, gpio_dir = 0;
  wire [31:0] rdata;
  wire ack, err, pin_data, pin_dir;
  pulse_gen dut (
    .bus_clk_i(bus_clk), .fast_clk_i(fast_clk), .arstn_i(arstn),
    .sys_addr_i(addr), .sys_wdata_i(wdata), .sys_wen_i(wen), .sys_ren_i(ren),
    .sys_rdata_o(rdata), .sys_ack_o(ack), .sys_err_o(err),
    .gpio_data_i(gpio_data), .gpio_dir_i(gpio_dir),
    .pin_data_o(pin_data), .pin_dir_o(pin_dir)
  );

  task automatic wr(input [15:0] offset, input [31:0] value, input bit expect_error = 0);
    @(negedge bus_clk); addr = {16'h4072, offset}; wdata = value; wen = 1;
    @(posedge bus_clk); #0.01;
    if (!ack || err != expect_error) $fatal(1, "Write %h ACK/ERR mismatch", offset);
    @(negedge bus_clk); wen = 0;
  endtask
  task automatic rd(input [15:0] offset, output [31:0] value, input bit expect_error = 0);
    @(negedge bus_clk); addr = {16'h4072, offset}; ren = 1;
    @(posedge bus_clk); #0.01;
    if (!ack || err != expect_error) $fatal(1, "Read %h ACK/ERR mismatch", offset);
    value = rdata;
    @(negedge bus_clk); ren = 0;
  endtask
  task automatic idle;
    reg [31:0] status;
    integer attempts;
    attempts = 0; status = 0;
    while ((!status[4] || status[0]) && attempts < 40) begin
      rd(16'h0008, status); attempts = attempts + 1;
    end
    if (attempts == 40) $fatal(1, "Mailbox timeout");
  endtask
  task automatic stop;
    wr(16'h0004, 0); wr(16'h0014, 1); idle();
    #12;
    if (pin_data !== 0 || pin_dir !== 1) $fatal(1, "OFF must hold claimed GPIO LOW");
  endtask
  task automatic start(input [31:0] period_ns, input [31:0] high_ns);
    wr(16'h000c, period_ns/32'd2); wr(16'h0010, high_ns/32'd2);
    wr(16'h0004, 1); wr(16'h0014, 1); idle();
    if (pin_dir !== 1) $fatal(1, "ON must claim GPIO");
  endtask
  task automatic waveform(input realtime period_ns, input realtime high_ns, input integer count);
    realtime rise_time;
    @(posedge pin_data); rise_time = $realtime;
    repeat (count) begin
      @(negedge pin_data);
      if ($realtime-rise_time < high_ns-0.001 || $realtime-rise_time > high_ns+0.001)
        $fatal(1, "HIGH measured %0.3f, expected %0.3f", $realtime-rise_time, high_ns);
      @(posedge pin_data);
      if ($realtime-rise_time < period_ns-0.001 || $realtime-rise_time > period_ns+0.001)
        $fatal(1, "Period measured %0.3f, expected %0.3f", $realtime-rise_time, period_ns);
      rise_time = $realtime;
    end
  endtask

  reg [31:0] value;
  initial begin
    #19; arstn = 1; #48; idle();
    rd(0, value); if (value != 32'h50554c01) $fatal(1, "ID mismatch");
    rd(16'h0018, value); if (value != 2) $fatal(1, "Timing unit mismatch");
    rd(16'h001c, value); if (value != 1) $fatal(1, "GPIO index mismatch");
    gpio_dir = 1; gpio_data = 1; #12;
    if (pin_data !== 1 || pin_dir !== 1) $fatal(1, "Normal GPIO passthrough failed");
    gpio_data = 0; #12;

    // Saved GPIO data may be HIGH while its direction is IN. On claiming it,
    // the output driver must first see LOW, not leak a pre-start HIGH pulse.
    gpio_dir = 0; gpio_data = 1;
    fork
      begin
        @(posedge pin_dir); #0.01;
        if (pin_data !== 0) $fatal(1, "Claim leaked saved HIGH GPIO data");
      end
      begin start(8, 4); waveform(8, 4, 20); stop(); end
    join
    // The independent claim synchronizer can settle later than the request
    // synchronizer. Emulate that CDC skew: no waveform may start before the
    // pin has first been enabled LOW, even with a long initial HIGH interval.
    wr(16'h0014, 2); idle();
    gpio_dir = 0; gpio_data = 1;
    force dut.claim_sync = 2'b00;
    wr(16'h000c, 500); wr(16'h0010, 250);
    wr(16'h0004, 1); wr(16'h0014, 1);
    wait (dut.active_enable === 1'b1);
    repeat (4) @(negedge fast_clk);
    if (pin_dir !== 0) $fatal(1, "Driver claimed before claim synchronization");
    fork
      begin
        @(posedge pin_dir); #0.01;
        if (pin_data !== 0) $fatal(1, "Claim/request CDC skew bypassed LOW startup guard");
      end
      begin
        release dut.claim_sync;
        idle(); waveform(1000, 500, 3); stop();
      end
    join
    gpio_dir = 1; gpio_data = 0;
    start(4, 2); waveform(4, 2, 20); stop();
    start(8, 2); waveform(8, 2, 20); stop();
    start(8, 6); waveform(8, 6, 20); stop();
    start(24, 12); waveform(24, 12, 20); stop();
    start(1000, 250); waveform(1000, 250, 10);

    // Live timing updates are rejected and leave the running waveform intact.
    wr(16'h000c, 8); wr(16'h0010, 4);
    // A lagging ENABLE status synchronizer must not authorize a live update.
    force dut.enable_sync = 2'b00;
    wr(16'h0014, 1, 1);
    release dut.enable_sync;
    waveform(1000, 250, 3);
    rd(16'h0020, value); if (value != 500) $fatal(1, "Rejected update changed active period");
    wr(16'h0014, 4); stop();

    // Invalid periods/widths must never launch a request.
    wr(16'h000c, 3); wr(16'h0010, 1); wr(16'h0014, 1, 1); // odd period
    wr(16'h000c, 4); wr(16'h0010, 0); wr(16'h0014, 1, 1); // zero HIGH
    wr(16'h0010, 4); wr(16'h0014, 1, 1);                 // no LOW
    wr(16'h000c, 0); wr(16'h0010, 1); wr(16'h0014, 1, 1);
    wr(16'h000c, 32'hfffffffe); wr(16'h0010, 32'hfffffffd);
    wr(16'h0014, 4); wr(16'h0014, 1); idle();
    rd(16'h0020, value); if (value != 32'hfffffffe) $fatal(1, "Maximum period lost bits");

    // Hold fast clock, send one request, then try another. Mailbox must freeze.
    @(negedge fast_clk); fast_run = 0;
    wr(16'h000c, 10); wr(16'h0010, 5); wr(16'h0014, 1);
    wr(16'h000c, 14); wr(16'h0010, 7); wr(16'h0014, 1, 1);
    fast_run = 1; idle();
    rd(16'h0020, value); if (value != 10) $fatal(1, "Busy request overwrote mailbox");
    wr(16'h0014, 2); idle(); gpio_data = 1; #12;
    if (pin_data !== 1 || pin_dir !== 1) $fatal(1, "Reset did not return GPIO ownership");
    rd(16'h0020, value); if (value != 500000) $fatal(1, "Reset default mismatch");
    rd(16'h00fc, value, 1);
    wr(16'h0000, 0, 1);

    // Reset assertion must work while the fast clock is stopped.
    start(8, 4); @(negedge fast_clk); fast_run = 0;
    arstn = 0; #2;
    if (pin_data !== 0) $fatal(1, "ODDR asynchronous reset failed");
    fast_run = 1; arstn = 1; #48; idle();
    rd(16'h0008, value); if ((value & 15) != 0) $fatal(1, "Reset did not clear state");
    $display("tb_pulse_gen: PASS"); $finish;
  end
  initial begin #100000; $fatal(1, "Testbench watchdog timeout"); end
endmodule
