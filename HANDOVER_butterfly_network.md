# Red Pitaya Butterfly Network Handover

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
  -> ASG channel A waveform memory
  -> ASG stream asg_dat[0]
  -> butterfly_network
  -> butterfly_dat[0], butterfly_dat[1]
  -> existing DAC format/output path
  -> DAC OUT1, DAC OUT2
```

The normal Red Pitaya ASG still exists and is still configured by software, but its channel A stream is intercepted before the physical DAC output.

The current butterfly behavior is a neighboring-pair butterfly over one sample stream:

```text
input stream:
  x[0], x[1], x[2], x[3], ...

pair 0:
  y0 = (x[0] + x[1]) / 2
  y1 = (x[0] - x[1]) / 2

pair 1:
  y0 = (x[2] + x[3]) / 2
  y1 = (x[2] - x[3]) / 2
```

The outputs are:

```text
DAC OUT1 = y0, the normalized pair sum
DAC OUT2 = y1, the normalized pair difference
```

## Files Changed

### `prj/v0.94/rtl/butterfly_network.sv`

New module.

Current ports:

```systemverilog
module butterfly_network #(
  parameter int unsigned IN_DW  = 14,
  parameter int unsigned OUT_DW = 14
)(
  input  logic                     clk_i,
  input  logic                     rstn_i,

  input  logic signed [IN_DW-1:0]  sample_i,

  output logic signed [OUT_DW-1:0] y0_o,
  output logic signed [OUT_DW-1:0] y1_o
);
```

Internal behavior:

- Stores the first/even sample of a pair in `first_sample`.
- Uses `pair_phase` to track whether the next sample is first or second in the pair.
- On the second/odd sample, computes:

```systemverilog
sum  = first_sample + sample_i;
diff = first_sample - sample_i;
sum_norm  = sum  >>> 1;
diff_norm = diff >>> 1;
```

- Outputs update only when a full pair is available.
- Outputs hold their previous value during the first sample of the next pair.

### `prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv`

Important changes:

- Added `butterfly_dat` signal:

```systemverilog
SBG_T [2-1:0] butterfly_dat;
```

- Instantiated `butterfly_network` in the DAC IO section:

```systemverilog
butterfly_network #(
  .IN_DW  (14),
  .OUT_DW (14)
) i_butterfly_network (
  .clk_i    (adc_clk),
  .rstn_i   (adc_rstn),
  .sample_i (asg_dat[0]),
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

- The input is currently only `asg_dat[0]`, meaning ASG channel A.
- ASG channel B still exists but is not currently used by the butterfly.
- The module processes neighboring samples in time, not two separate channels.
- Use an even number of waveform samples for clean repeated testing.
- Because outputs update once per pair, the effective output update rate is half the input sample-pair rate.
- The divide by 2 is fixed normalization. This avoids clipping for a basic butterfly stage.
- There is no runtime SCPI-configurable weight/register yet.
- The previously discussed fixed weight/twiddle idea was removed when switching to the neighboring-pair design.

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

Use SCPI/API to load a known waveform into ASG channel A.

Example conceptual input vector:

```text
x = [1000, 500, 2000, -1000, ...]
```

Expected pairwise outputs:

```text
pair 0:
  DAC OUT1 = (1000 + 500) / 2 = 750
  DAC OUT2 = (1000 - 500) / 2 = 250

pair 1:
  DAC OUT1 = (2000 + -1000) / 2 = 500
  DAC OUT2 = (2000 - -1000) / 2 = 1500
```

Observe DAC OUT1 and DAC OUT2 on an oscilloscope.

## Possible Next Steps

1. Add a valid/strobe signal so downstream logic knows exactly when a new pair output is valid.
2. Decide whether DAC outputs should hold between pairs, repeat each pair result for two samples, or output at half rate with explicit timing.
3. Add a second butterfly stage:

```text
stage 1: neighboring pairs, distance 1
stage 2: pairs separated by distance 2
stage 3: pairs separated by distance 4
```

4. Add twiddle factors/weights for FFT-style butterflies.
5. Add software-writable registers for stage control, weights, or mode selection.
6. Consider buffering if a full vector transform is needed rather than a streaming approximation.

## Current Git Status at Handover Time

Relevant modified/untracked files:

```text
M  prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
?? prj/v0.94/rtl/butterfly_network.sv
?? HANDOVER_butterfly_network.md
```

No full Vivado synthesis/lint was run in this environment.
