# Red Pitaya Butterfly Network Handover

## Current Status Update - 2026-06-04

This file originally described the first ASG-fed butterfly milestone. The
hardware has since advanced to a DDR-backed BNET reader prototype.

For the most current compile-check handover, use:

```text
HANDOVER_bnet_ddr_reader_compile_check.md
```

Board-debug update from 2026-06-08:

- The current failure is no longer the original ASG-fed butterfly milestone.
- `BNET:RST` initially did not reset the DDR readers or staged butterfly FSM;
  that reset propagation bug has been fixed in the newer HDL.
- A later DDR smoke test showed partial stream consumption
  (`stream0_rptr=1152` vs expected `2048`, `stream1_rptr=7552` vs expected
  `20480`) and `STATUS=0x1` busy forever.
- The likely reader-side cause was overlapping AXI read burst requests caused
  by the delayed `axi_rd_burst.ctrl_busy_o` handshake. The newer DDR-reader
  handover records the fix in `bnet_axi_reader_ch.sv`.
- A second reader-side bug was then fixed with an AXI-clock skid buffer between
  `axi_rd_burst` and the async FIFO, preventing lost beats when the FIFO write
  side was reset-busy/full.
- Latest board tests now pass for the fixed `VECTOR_LEN=1024` DDR-backed staged
  network:

```text
stream 0: 2048 / 2048 bytes consumed
stream 1: 20480 / 20480 bytes consumed
STATUS=0x12
ERROR=0
RF OUT1 loopback correlation against PC model: 0.994..1.000 across trials
```

- The remaining architectural goal is no longer fixing the fixed-length DDR
  smoke path. The next milestone is larger input sizes and true DDR streaming:
  overlap/refill ping-pong or ring buffers so the hardware runs at a higher
  sustained rate instead of doing one software-uploaded batch per `BNET:START`.
- Use `HANDOVER_bnet_ddr_reader_compile_check.md` for all DDR-mode debug,
  validation expectations, and remaining risks.

That newer handover covers:

- BNET input source selection through `CONFIG[1:0]`.
- ADC, ASG-test, and DDR-stream BNET input modes.
- The new `bnet_axi_reader_ch.sv` DDR reader.
- Use of `axi2_sys` and `axi3_sys` for BNET streams 0 and 1.
- ASG deep-memory AXI stubbing while preserving normal ASG BRAM/table mode.
- Reader consume/valid handshaking for sample/weight alignment.
- Read-pointer and runtime-error feedback into `bnet_regs`.

The current signal-chain target is:

```text
ADC or ASG test input or DDR stream input
  -> BNET compute block
  -> DAC output path
```

Relevant current hardware files:

```text
prj/v0.94/rtl/bnet_regs.sv
prj/v0.94/rtl/butterfly_network.sv
prj/v0.94/rtl/bnet_axi_reader_ch.sv
prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
```

Use Vivado 2020.1 for the first real compile/synthesis check. No Vivado compile
was run on the PC where these edits were made.

## Project Context

Repository/workspace:

`C:\Users\Kevin Huang\VS code\RP_fpga\RedPitaya-FPGA`

Main edited top file:

`prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv`

New module file:

`prj/v0.94/rtl/butterfly_network.sv`

The goal is to use the Red Pitaya FPGA fabric to process waveform data loaded from a PC through SCPI/API, then output the processed result through the DAC outputs.

## Current Implemented Architecture

The current hardware path is:

```text
PC / SCPI / API
  -> ASG channel A waveform memory: input vector samples
  -> ASG channel B waveform memory: packed butterfly weights
  -> ASG streams asg_dat[0], asg_dat[1]
  -> butterfly_network local sample/weight RAM capture
  -> one RAM-to-RAM neighboring-pair butterfly stage
  -> butterfly_dat[0], butterfly_dat[1]
  -> existing DAC format/output path
  -> DAC OUT1, DAC OUT2
```

The normal Red Pitaya ASG still exists and is still configured by software, but both ASG streams are intercepted before the physical DAC output.

The current butterfly behavior is a RAM-backed weighted first-stage neighboring-pair butterfly. ASG channel A carries the input vector:

```text
input stream:
  x[0], x[1], x[2], x[3], ...
```

ASG channel B carries one packed 14-bit weight word per input sample:

```text
w[n][13:7] = signed 7-bit Q1.6 weight for DAC OUT1 / y0
w[n][ 6:0] = signed 7-bit Q1.6 weight for DAC OUT2 / y1
```

The FPGA captures `VECTOR_LEN` samples and `VECTOR_LEN` packed weight words into local RAM, then computes each neighboring pair:

```text
pair 0:
  y0 = x[0] * w[0].y0 + x[1] * w[1].y0
  y1 = x[0] * w[0].y1 + x[1] * w[1].y1

pair 1:
  y0 = x[2] * w[2].y0 + x[3] * w[3].y0
  y1 = x[2] * w[2].y1 + x[3] * w[3].y1
```

After multiply/add, the accumulator is shifted right by 6 bits to convert the Q1.6 weighted result back to sample scale, then saturated to 14 bits. Pair outputs are written into local output RAMs and then played back to the DAC, one pair per clock.

This implements the "two weights per input element" idea while using the two existing ASG channels:

```text
input element x[n] has two weights:
  one contribution weight for y0
  one contribution weight for y1
```

The outputs are:

```text
DAC OUT1 = y0, weighted first butterfly output
DAC OUT2 = y1, weighted second butterfly output
```

## Files Changed

### `prj/v0.94/rtl/butterfly_network.sv`

New module.

Current ports:

```systemverilog
module butterfly_network #(
  parameter int unsigned IN_DW  = 14,
  parameter int unsigned OUT_DW = 14,
  parameter int unsigned WEIGHT_DW   = 7,
  parameter int unsigned WEIGHT_FRAC = 6,
  parameter int unsigned VECTOR_LEN  = 1024
)(
  input  logic                     clk_i,
  input  logic                     rstn_i,
  input  logic                     start_i,

  input  logic signed [IN_DW-1:0]  sample_i,
  input  logic signed [2*WEIGHT_DW-1:0] weight_i,

  output logic signed [OUT_DW-1:0] y0_o,
  output logic signed [OUT_DW-1:0] y1_o
);
```

Current default parameters:

```systemverilog
IN_DW       = 14
OUT_DW      = 14
WEIGHT_DW   = 7
WEIGHT_FRAC = 6
VECTOR_LEN  = 1024
```

Internal behavior:

- `ST_IDLE`: waits for `start_i`, currently connected to the ASG trigger notification pulse.
- `ST_CAPTURE`: stores ASG A samples into `sample_ram` and ASG B packed weights into `weight_ram`.
- `ST_COMPUTE_READ`: reads two neighboring samples and their two packed weight words from RAM.
- `ST_COMPUTE_WRITE`: computes one weighted butterfly pair and writes `y0_ram` / `y1_ram`.
- `ST_PLAYBACK`: loops over the completed pair-output RAMs and drives DAC OUT1 / DAC OUT2.

For each pair it computes:

```systemverilog
y0 = first_sample * first_weight_y0 + sample_i * weight_y0;
y1 = first_sample * first_weight_y1 + sample_i * weight_y1;
y0_scaled = y0 >>> WEIGHT_FRAC;
y1_scaled = y1 >>> WEIGHT_FRAC;
```

- Saturates the scaled results to `OUT_DW`.
- Output playback starts only after the whole captured vector has been processed.

### `prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv`

Important changes:

- Added `butterfly_dat` signal:

```systemverilog
SBG_T [2-1:0] butterfly_dat;
```

- Instantiated `butterfly_network` in the DAC IO section:

```systemverilog
butterfly_network #(
  .IN_DW       (14),
  .OUT_DW      (14),
  .WEIGHT_DW   (7),
  .WEIGHT_FRAC (6),
  .VECTOR_LEN  (1024)
) i_butterfly_network (
  .clk_i    (adc_clk),
  .rstn_i   (adc_rstn),
  .start_i  (trig_asg_out),
  .sample_i (asg_dat[0]),
  .weight_i (asg_dat[1]),
  .y0_o     (butterfly_dat[0]),
  .y1_o     (butterfly_dat[1])
);
```

- Changed the DAC source from the original ASG + PID sum:

```systemverilog
assign dac_a_sum = asg_dat[0] + pid_dat[0];
assign dac_b_sum = asg_dat[1] + pid_dat[1];
```

to:

```systemverilog
assign dac_a_sum = {butterfly_dat[0][14-1], butterfly_dat[0]};
assign dac_b_sum = {butterfly_dat[1][14-1], butterfly_dat[1]};
```

This means the DAC physical outputs now come from the butterfly result, not directly from ASG or PID.

## Important Behavioral Notes

- The input vector is currently `asg_dat[0]`, meaning ASG channel A.
- The weight stream is currently `asg_dat[1]`, meaning ASG channel B.
- Each 14-bit ASG-B sample packs two signed 7-bit Q1.6 weights.
- `VECTOR_LEN` must be even. Current top-level value is 1024.
- The module waits for ASG trigger notification, captures one vector, computes one full neighboring-pair stage, then loops playback of the result.
- The module processes neighboring samples from RAM, not two separate input-vector channels.
- Use an ASG waveform length and generator configuration that repeatedly presents the intended first `VECTOR_LEN` samples after reset/trigger.
- During output playback, DAC OUT1/DAC OUT2 update once per computed pair.
- Weight scaling is fixed by `WEIGHT_FRAC = 6`, so a weight value of `63` represents approximately `+0.984375`, and `-64` represents `-1.0`.
- There is no runtime SCPI-configurable weight/register yet.
- The design uses the existing ASG waveform memories as the temporary software-loaded weight source.

## Vivado Notes

Make sure `butterfly_network.sv` is added as a design source.

In Vivado GUI:

1. Open **Sources**.
2. Right-click **Design Sources**.
3. Choose **Add Sources**.
4. Choose **Add or create design sources**.
5. Add:

```text
prj/v0.94/rtl/butterfly_network.sv
```

The file does not need to be physically inside `red_pitaya_top`. It remains a separate module, instantiated by `red_pitaya_top_LED7_mod.sv`.

Expected hierarchy:

```text
red_pitaya_top
  i_butterfly_network : butterfly_network
```

## Suggested Verification

Use SCPI/API to load a known input waveform into ASG channel A and a packed weight waveform into ASG channel B.

Example conceptual input vector:

```text
x = [1000, 500, 2000, -1000, ...]
```

For a classic sum/difference-like first stage, pack weights like this:

```text
w0.y0 = +0.5 -> 32
w0.y1 = +0.5 -> 32
w1.y0 = +0.5 -> 32
w1.y1 = -0.5 -> -32

packed w0 = {7'sd32,  7'sd32}
packed w1 = {7'sd32, -7'sd32}
```

Expected pair 0 output:

```text
pair 0:
  DAC OUT1 = (1000*32 + 500*32) >>> 6 = 750
  DAC OUT2 = (1000*32 + 500*-32) >>> 6 = 250
```

Observe DAC OUT1 and DAC OUT2 on an oscilloscope.

## Possible Next Steps

1. Add a valid/strobe signal so downstream logic knows exactly when a new pair output is valid.
2. Decide whether DAC outputs should hold between pairs, repeat each pair result for two samples, or output at half rate with explicit timing.
3. Decide whether 7-bit packed weights are enough, or whether the next revision should add a dedicated weight RAM/register file for full 14-bit or wider weights.
4. Add a second butterfly stage:

```text
stage 1: neighboring pairs, distance 1
stage 2: pairs separated by distance 2
stage 3: pairs separated by distance 4
```

5. Add twiddle factors/weights for FFT-style butterflies.
6. Add software-writable registers for stage control, weights, or mode selection.
7. Consider buffering if a full vector transform is needed rather than a streaming approximation.

## Current Git Status at Handover Time

Relevant modified/untracked files:

```text
M  HANDOVER_butterfly_network.md
M  prj/v0.94/rtl/butterfly_network.sv
M  prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
```

No full Vivado synthesis/lint was run in this environment.
