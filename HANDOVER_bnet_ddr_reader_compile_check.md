# Red Pitaya BNET FPGA Handover

Date: 2026-06-11

Repository:

```text
RedPitaya-FPGA
```

Target:

```text
Project: prj/v0.94
MODEL: Z20_G2
Board: Red Pitaya STEMlab 125-14 Zynq-7020 Gen 2
Recommended Vivado: 2020.1
```

## Current Status

The BNET hardware path is:

```text
ASG test stream, ADC stream, or DDR stream
  -> BNET compute block
  -> DAC output path
```

Board-proven milestone:

- The fixed `VECTOR_LEN=1024` DDR-backed staged engine has passed board tests.
- Stream 0 consumed `2048/2048` bytes.
- Stream 1 consumed `20480/20480` bytes.
- BNET reported `STATUS=0x12`, `ERROR=0`.
- RF OUT1 loopback matched the PC-side fixed-point reference with high
  waveform correlation across ramp/sine/triangle/cosine tests.

Current source status:

- The source now targets `VECTOR_LEN=2048`.
- Timing counters, guarded ping-pong auto-swap, auto-restart, and static-weight
  reuse control have been added.
- A first fixed-weight frame-pipeline RTL draft is wired into the top level
  behind `CONFIG[5]` for DDR mode.
- Rebuild in Vivado GUI and board-test before treating the 2048 path or the new
  pipeline draft as validated.

## Important Files

```text
prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
prj/v0.94/rtl/bnet_regs.sv
prj/v0.94/rtl/bnet_axi_reader_ch.sv
prj/v0.94/rtl/butterfly_network.sv
prj/v0.94/rtl/butterfly_network_static_pipeline.sv
```

The Vivado project flow normally adds the whole `prj/v0.94/rtl` directory, so
new RTL files there should be picked up by the project/non-project build.

## Architecture

BNET uses Red Pitaya system bus slot `sys[7]`.

The DDR mode takes over the two AXI HP ports that normally support ASG
deep-memory generation:

```text
axi2_sys -> BNET stream 0, input samples
axi3_sys -> BNET stream 1, packed weights
```

Normal ASG BRAM/table mode remains useful for test stimulus. ASG deep-memory
AXI is intentionally stubbed in this BNET bitstream so BNET can own `axi2_sys`
and `axi3_sys`.

Input source selection is controlled by `CONFIG[1:0]`:

```text
0 = ASG test stream: sample=ASG A, weight=ASG B
1 = ADC real-time stream: sample=ADC A, weight=ASG B
2 = DDR stream: sample=stream 0, weight=stream 1
```

## Module Responsibilities

### `bnet_regs.sv`

Purpose:

- Owns the BNET register block on `sys[7]`.
- Exposes scalar/debug registers, stream descriptors, input mode, status,
  timing counters, and ping-pong controls.
- Emits one-clock `start_pulse_o` and `soft_reset_pulse_o`.
- Tracks active/pending stream buffers and descriptor errors.

Important `CONFIG` bits:

```text
bits 1:0 = input mode
bit 2    = auto-swap to valid pending ping/pong buffers on compute done
bit 3    = auto-restart after successful auto-swap
bit 4    = static weight reuse for the current serial engine
bit 5    = fixed-weight frame pipeline select in DDR mode
```

Static weight reuse preserves the variable-weight training path. Run once with
bit 4 clear to load `VECTOR_LEN * log2(VECTOR_LEN)` weights into the current
serial engine's weight RAM. Then set bit 4 and run with stream 0 only; the
engine skips stream 1 and reuses the BRAM-resident weights.

### `bnet_axi_reader_ch.sv`

Purpose:

- Reads a ping/pong-selected DDR buffer through `axi_sys_if`.
- Uses existing `axi_rd_burst`.
- Uses existing `asg_dat_fifo` to cross from `dac_axi_clk` to `adc_clk`.
- Splits each 64-bit AXI beat into four 16-bit lanes and emits the low 14 bits
  of each lane as one signed BNET word.
- Holds output stable until `consume_i`.
- Reports read pointer, underrun, and debug status.

Important details:

- Burst requests are limited to 16 AXI beats at a time.
- `stride_bytes_i` currently only affects read-pointer accounting; it does not
  skip lanes in hardware.
- `FORMAT` is stored/exported but not interpreted.
- Runtime underrun is not sticky.

### `butterfly_network.sv`

Purpose:

- Current active compute engine.
- Serial full staged radix-2 fixed-point butterfly network.
- Supports variable weights for training.
- Loads input samples and full staged weights, computes all stages through
  ping-pong vector RAMs, then loops final-vector playback to DAC A/B.

Default source shape:

```text
VECTOR_LEN     = 2048
STAGE_COUNT    = log2(2048) = 11
PAIR_COUNT     = 1024 butterflies per stage
TOTAL_WEIGHTS  = 22528 packed weight words
```

Input sizes:

```text
stream 0 = VECTOR_LEN * 2 bytes
stream 1 = VECTOR_LEN * log2(VECTOR_LEN) * 2 bytes
```

For the current 2048 source:

```text
stream 0 = 4096 bytes
stream 1 = 45056 bytes
```

Packed weight format:

```text
weight[13:7] = contribution to first butterfly output
weight[ 6:0] = contribution to second butterfly output
```

Weights are signed 7-bit Q1.6. `+1.0` is not exactly representable; use
`+63/64` for near-identity pass-through and `-64/64` for `-1.0`.

The current serial engine is `N log N` elapsed compute time:

```text
compute cycles ~= log2(N) * (N / 2) * clocks_per_butterfly
```

After the BRAM wrapper and serialized multiplier changes, the rough 1024-vector
estimate is about:

```text
log2(1024) * 512 * 7 ~= 35840 clocks
```

### `butterfly_network_static_pipeline.sv`

Purpose:

- First fixed-weight pipeline RTL draft.
- Separate from the current active variable-weight training engine.
- Preloads per-stage static weights into BRAM.
- Gives each butterfly stage its own worker and ping-pong frame buffers.
- Intended steady-state throughput target is one frame per stage-pass after the
  pipeline fills, instead of one frame per all-stage serial pass.

Current status:

- Added as RTL and wired into `red_pitaya_top_LED7_mod.sv` behind `CONFIG[5]`.
- Needs Vivado GUI elaboration/synthesis review.
- Top-level mux selects its stream ready signals, DAC output, busy/done status,
  and timing output when `CONFIG[5]` is set and `CONFIG[1:0] == 2`.
- This is a frame pipeline, not yet the final sample-by-sample SDF pipeline.

### `red_pitaya_top_LED7_mod.sv`

Purpose:

- Connects BNET register block, DDR readers, input mux, compute engine, and DAC
  path.
- Stubs ASG deep-memory AXI through dummy interfaces while preserving ASG
  BRAM/table mode.
- Drives DAC A/B from `butterfly_dat[0]` and `butterfly_dat[1]`.

Current active compute output:

```text
butterfly_network.sv -> butterfly_dat[0] -> DAC A / RF OUT1
butterfly_network.sv -> butterfly_dat[1] -> DAC B / RF OUT2
```

## Register Summary

Offsets are relative to BNET base `0x00700000`.

```text
0x00 CONTROL
0x04 STATUS
0x08..0x24 CH0..CH7 scalar/debug registers
0x28..0x34 OUT0..OUT3 scalar/debug outputs
0x38 VECTOR_LEN
0x3c STREAM_COUNT
0x40 ACTIVE_MASK
0x44 PENDING_MASK
0x48 ERROR_MASK
0x4c CONFIG
0x50 TIME_TOTAL
0x54 TIME_LOAD
0x58 TIME_COMPUTE
0x5c TIME_PLAYBACK
0x100 + n*0x40 stream descriptor window
```

`STATUS` bits currently used:

```text
bit 0 = busy
bit 1 = done, sticky until next START/reset
bit 3 = any stream pending
bit 4 = output playback valid
```

Per-stream descriptor window:

```text
+0x00 BASE0
+0x04 BASE1
+0x08 LENGTH_BYTES
+0x0c STRIDE_BYTES
+0x10 FORMAT
+0x14 CONTROL
+0x18 STATUS
+0x1c READ_PTR
+0x20 DBG0
+0x24 DBG1
```

Per-stream `CONTROL` bits:

```text
bit 0 = enable stream
bit 1 = commit buffer 0
bit 2 = commit buffer 1
bit 3 = force swap
bit 4 = clear descriptor/runtime error
```

## DDR Test Flow

For current variable-weight DDR mode:

```text
1. Reserve/upload stream 0 input vector.
2. Reserve/upload stream 1 full staged weight vector.
3. Attach stream 0 and stream 1 descriptors.
4. Enable both streams.
5. Commit selected ping/pong buffers.
6. Set CONFIG = 2 for DDR one-shot.
7. Write CONTROL[0] start.
8. Poll STATUS, ERROR, stream STATUS, READ_PTR, and timing counters.
```

Useful CONFIG values:

```text
2  = DDR one-shot
6  = DDR + auto-swap
14 = DDR + auto-swap + auto-restart
18 = DDR one-shot + static weight reuse in the current serial engine
34 = DDR one-shot + fixed-weight frame pipeline
```

Expected read pointers for 2048 source:

```text
stream0 READ_PTR -> 4096
stream1 READ_PTR -> 45056
```

For `CONFIG=18`, stream 1 is intentionally skipped after weights have already
been loaded by a previous run.

For `CONFIG=34`, the fixed-weight pipeline consumes stream 1 until its static
weight preload is complete, then consumes stream 0 input frames. The sample
reader may start on the same `CONTROL[0]` pulse, but the pipeline keeps
`sample_ready_o` low until weight preload completes.

## Bugs To Avoid

### 1. Soft Reset Must Reset Readers And Compute FSM

Original symptom:

```text
BNET:RST
BNET:STREAM0:RPTR? -> nonzero
BNET:STREAM1:RPTR? -> nonzero
```

Root cause:

- `bnet_regs.sv` handled soft reset internally but did not export it.
- DDR readers and `butterfly_network.sv` kept stale runtime state.

Fix to preserve:

- `bnet_regs.sv` exports `soft_reset_pulse_o`.
- `red_pitaya_top_LED7_mod.sv` wires it to both DDR readers and the compute
  engine.
- `bnet_axi_reader_ch.sv` resets visible read pointer/output state and AXI-side
  FSM/FIFO state.
- `butterfly_network.sv` includes `soft_reset_i` in its FSM reset condition.

### 2. Do Not Issue Overlapping AXI Bursts From Delayed `ctrl_busy_o`

Original symptom:

```text
STATUS busy forever
stream0_rptr stopped early
stream1_rptr stopped early
```

Root cause:

- `axi_rd_burst.ctrl_busy_o` is registered/delayed.
- The reader could issue another `ctrl_val` before the previous burst was
  visibly busy.
- `bytes_requested_axi` could run ahead of actual delivered data.

Fix to preserve:

- Keep `ctrl_req_inflight_axi` and `ctrl_busy_seen_axi`.
- Issue one burst, wait until busy is observed, wait until idle, then allow the
  next burst.

### 3. Do Not Drop AXI Read Beats At FIFO Boundary

Original symptom:

- Stream 0 completed but longer stream 1 stopped early, for example
  `14032/20480` bytes.

Root cause:

- AXI read data was connected too directly to the async FIFO write side.
- A valid beat could arrive while FIFO write side was reset-busy/full.

Fix to preserve:

- Keep the AXI-clock skid buffer between `axi_rd_burst` and `asg_dat_fifo`.
- Drive AXI `rd_drdy_i` from skid-buffer capacity.
- Drain skid buffer into FIFO only when FIFO write side is ready.
- Do not request the next burst until the skid buffer has drained.

### 4. RF OUT1 Is The Even-Indexed Final Vector Half

`butterfly_network.sv` playback emits two final-vector samples per clock:

```text
DAC A / RF OUT1 = expected[0], expected[2], expected[4], ...
DAC B / RF OUT2 = expected[1], expected[3], expected[5], ...
```

RF OUT1 validation must compare against `expected[0::2]`, not the full PC
reference vector.

### 5. BRAM Inference Is Critical

Vivado previously over-used LUT resources when large memories were not inferred
as BRAM.

Fixes already applied:

- Added BRAM style hints.
- Replaced raw arrays with explicit `bnet_tdp_ram`.
- Updated `bnet_tdp_ram` to use one clocked write process per RAM port, because
  Vivado 2020.1 did not infer RAM from two write ports in one process.

Template to preserve:

```systemverilog
always_ff @(posedge clk_i) begin
  if (we_a_i) ram[addr_a_i] <= din_a_i;
  dout_a_o <= ram[addr_a_i];
end

always_ff @(posedge clk_i) begin
  if (we_b_i) ram[addr_b_i] <= din_b_i;
  dout_b_o <= ram[addr_b_i];
end
```

Check synthesis reports to confirm vector RAMs and weight RAMs infer as block
RAM, not LUT/register fabric.

## Diagnostics Still Needed

Useful future counters/status:

```text
bytes_requested_axi
delivered AXI beat count
consumed sample/word count
running_axi
ctrl_req_inflight_axi
ctrl_busy
FIFO empty/full/reset-busy flags
butterfly load state
sample_wr_addr
weight_wr_addr
samples_loaded
weights_loaded
stream starvation/backpressure cycles
```

Current underrun reporting is weak because top-level `consume_i` is gated by
reader `valid_o`. A real starvation flag should detect:

```text
DDR mode && compute_ready && !reader_valid
```

## Validation Checklist

Before board testing:

- Confirm Vivado sees the updated `butterfly_network.sv` ports.
- Confirm Vivado sees `butterfly_network_static_pipeline.sv`.
- Confirm `CONFIG=34` selects the fixed-weight pipeline in DDR mode.
- Confirm only BNET drives `axi2_sys` and `axi3_sys`; ASG deep-memory AXI must
  remain on dummy interfaces.
- Confirm `asg_dat_fifo` remains 96-bit wide.
- Confirm `bnet_tdp_ram` infers BRAM.
- Check LUT/DSP/BRAM utilization and timing at `VECTOR_LEN=2048`.

Board tests:

- `BNET:RST` clears stream read pointers.
- DDR smoke test reaches expected `READ_PTR` values.
- `STATUS[1]` eventually sets.
- `ERROR_MASK` remains zero.
- Timing counters are nonzero after done.
- RF OUT1 compares against `expected[0::2]`.
- Multi-input stability still passes.
- Static-weight reuse mode: load weights once with `CONFIG=2`, then run a new
  input vector with `CONFIG=18` and verify stream 1 is not consumed.
- Static pipeline mode: use `CONFIG=34`, verify stream 1 reaches the full
  static-weight length, then stream 0 frames are consumed and RF output appears.

## Next Hardware Steps

1. Vivado GUI elaboration/synthesis for the current source.
2. Validate the existing serial engine at `VECTOR_LEN=2048`.
3. Review and synthesize `butterfly_network_static_pipeline.sv` and its
   top-level integration.
4. Board-test the CONFIG-selected paths:

```text
CONFIG=2  current variable-weight serial engine
CONFIG=18 current serial engine with weight reuse
CONFIG=34 new fixed-weight frame pipeline
```

5. Add richer static-pipeline timing counters and debug/status.
6. If frame-pipeline synthesis is acceptable, move toward a true sample
   streaming/SDF pipeline for lower first-frame latency.
