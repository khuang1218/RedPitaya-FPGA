# Red Pitaya BNET FPGA Handover

Date: 2026-06-23

Repository root:

```text
RedPitaya-FPGA/
```

Target:

```text
Project: prj/v0.94
Board/model: Red Pitaya STEMlab 125-14 Zynq-7020 Gen 2 / Z20_G2
Vivado used: 2020.1
Main edited RTL directory: prj/v0.94/rtl/
```

This handover is written so another ChatGPT/Codex session can review the HDL
architecture and judge whether it achieves the main purpose: run a DDR-backed
butterfly-network accelerator on Red Pitaya, compare the original variable
weight mode against a fixed-weight pipeline mode, and expose enough register/API
control to test both modes on hardware.

## Quick File Map

Important FPGA files, relative to `RedPitaya-FPGA/`:

```text
prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
prj/v0.94/rtl/bnet_regs.sv
prj/v0.94/rtl/bnet_axi_reader_ch.sv
prj/v0.94/rtl/butterfly_network.sv
prj/v0.94/rtl/butterfly_network_static_pipeline.sv
```

Useful context files:

```text
HANDOVER_bnet_ddr_reader_compile_check.md
HANDOVER_butterfly_network.md
vivado.log
```

The app/API/SCPI side is in the sibling repository:

```text
../RedPitaya_app/
../RedPitaya_app/scpi-tests/bnet_pipeline_mode_test.ipynb
```

## Main Hardware Goal

BNET is a custom FPGA butterfly-network data path:

```text
DDR/ASG/ADC sample source
  + packed butterfly weights
  -> BNET compute engine
  -> DAC output path
  -> RF OUT1/RF OUT2, optionally RF OUT1 only
```

There are currently two compute engines:

```text
butterfly_network.sv
  Original variable-weight serial staged engine.
  Loads a full weight stream each run unless static reuse is enabled.

butterfly_network_static_pipeline.sv
  New fixed-weight frame-pipeline engine.
  Preloads static weights once, then processes input frames through one worker
  per butterfly stage.
```

The intended comparison:

```text
Variable mode:
  load samples + load all weights + serial staged compute + playback

Static pipeline cold run:
  load static weights + load samples + frame-pipeline compute/playback

Static pipeline warm run:
  reuse static weights + load samples only + frame-pipeline compute/playback
```

The warm pipeline run is the important final target, because it should move
toward one vector/frame per stage-pass instead of reloading weights every run.

## Top-Level Architecture

`red_pitaya_top_LED7_mod.sv` is the integration point. It:

- connects the Zynq PS, DDR, ADC, DAC, scope, ASG, PID, GPIO, and daisy blocks;
- adds the BNET register block at Red Pitaya system bus slot `sys[7]`;
- gives BNET ownership of AXI HP ports `axi2_sys` and `axi3_sys`;
- stubs ASG deep-memory AXI while keeping ASG BRAM/table mode usable;
- selects between serial BNET and static-pipeline BNET;
- converts signed BNET output samples into the DAC negative-slope format.

Current important top-level constants:

```text
BNET_STREAM_COUNT      = 8
BNET_SERIAL_VECTOR_LEN = 2048
BNET_PIPE_VECTOR_LEN   = 4096
```

DDR stream ownership:

```text
axi2_sys -> BNET stream 0 -> input samples
axi3_sys -> BNET stream 1 -> packed weights
```

Input source selection is `CONFIG[1:0]` from `bnet_regs.sv`:

```text
0 = ASG test stream
    sample = ASG A
    weight = ASG B

1 = ADC real-time stream
    sample = ADC A
    weight = ASG B

2 = DDR stream mode
    sample = BNET stream 0
    weight = BNET stream 1
```

## Register Block: `bnet_regs.sv`

Purpose:

- Owns BNET control/status registers on `sys[7]`.
- Exposes BNET input mode, start/reset pulses, debug LEDs, stream descriptors,
  stream status, timing counters, and mode bits.
- Tracks active/pending ping-pong buffers and descriptor errors.

Important register offsets relative to the BNET base:

```text
0x00 CONTROL
0x04 STATUS
0x08..0x24 CH0..CH7 scalar/debug registers
0x28..0x34 OUT0..OUT3 simple scalar outputs
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
0x60 TIME_INPUT_LOAD
0x64 TIME_LATENCY
0x100 + n*0x40 stream descriptor window
```

Important `CONFIG` bits:

```text
bits 1:0 = input source mode
bit 2    = auto-swap pending stream buffers on compute done
bit 3    = auto-restart after auto-swap
bit 4    = serial-engine static weight reuse
bit 5    = select fixed-weight frame pipeline in DDR mode
bit 6    = serialize the full BNET vector onto DAC A / RF OUT1 only
```

Useful `CONFIG` values:

```text
2  = DDR one-shot, serial variable-weight engine
18 = DDR one-shot, serial engine with reused static weights
34 = DDR one-shot, static frame-pipeline engine
66 = DDR one-shot, serial engine, single-DAC serialized output
98 = DDR one-shot, static pipeline, single-DAC serialized output
```

`STATUS` bits currently used:

```text
bit 0 = busy
bit 1 = done, sticky until next START/reset
bit 3 = any stream pending
bit 4 = output_valid pulse mirror
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

## DDR Reader: `bnet_axi_reader_ch.sv`

Purpose:

- Reads one ping/pong-selected DDR buffer through `axi_sys_if`.
- Uses `axi_rd_burst` for AXI reads.
- Crosses from AXI/DAC clock domain to ADC/BNET clock domain with
  `asg_dat_fifo`.
- Splits each 64-bit AXI beat into four 16-bit lanes.
- Emits one signed 14-bit BNET word per consumed lane.

Important behavior:

```text
valid_o     = current 16-bit lane is available
sample_o    = low SAMPLE_DW bits of current lane
consume_i   = downstream accepts this lane
read_ptr_o  = increments by stride_bytes_i on consume_i
debug0_o    = packed internal status flags
debug1_o    = AXI bytes requested
```

Important limitation:

- `stride_bytes_i` currently affects pointer accounting only. It does not skip
  lanes in hardware.
- `FORMAT` is stored but not interpreted.
- Runtime underrun is exposed but not very rich; starvation diagnostics could be
  improved.

## Serial Engine: `butterfly_network.sv`

Purpose:

- Original active BNET compute engine.
- Full staged radix-2 butterfly network.
- Supports changing weights every run, which is needed for training-style
  experiments.
- Can reuse already-loaded weights if `CONFIG[4]` is set.

Compiled size:

```text
VECTOR_LEN     = BNET_SERIAL_VECTOR_LEN = 2048
STAGE_COUNT    = log2(2048) = 11
PAIR_COUNT     = 1024 butterflies per stage
TOTAL_WEIGHTS  = 2048 * 11 = 22528 packed weight words
```

Expected DDR bytes:

```text
stream 0 samples = 2048 * 2      = 4096 bytes
stream 1 weights = 2048 * 11 * 2 = 45056 bytes
```

Packed weight format:

```text
weight[13:7] = sample contribution to y0
weight[ 6:0] = sample contribution to y1
```

Weights are signed 7-bit Q1.6:

```text
+1.0 is not exactly representable; use +63/64
-1.0 is representable as -64/64
```

Internal structure:

- load input vector into local RAM;
- load staged weight stream into local weight RAM unless reuse is enabled;
- run all butterfly stages serially;
- use ping-pong vector RAMs between stages;
- play final vector back two samples per clock as `y0_o` and `y1_o`.

Timing counters:

```text
TIME0/TOTAL    start/load through compute/playback accounting
TIME1/LOAD     input + weight load cycles
TIME2/COMPUTE  staged compute cycles
TIME3/PLAYBACK final vector playback cycles
```

## Static Pipeline Engine: `butterfly_network_static_pipeline.sv`

Purpose:

- Fixed-weight frame-pipelined BNET path.
- Separate from the serial variable-weight engine.
- Preloads static weights once into per-stage RAMs.
- Moves complete input frames through one hardware worker per butterfly stage.

Compiled size:

```text
VECTOR_LEN     = BNET_PIPE_VECTOR_LEN = 4096
STAGE_COUNT    = log2(4096) = 12
TOTAL_WEIGHTS  = 4096 * 12 = 49152 packed weight words
```

Expected DDR bytes:

```text
stream 0 samples = 4096 * 2      = 8192 bytes
stream 1 weights = 4096 * 12 * 2 = 98304 bytes
```

Internal structure:

- top-level static pipeline controller;
- two input frame banks;
- `STAGE_COUNT` generated `butterfly_static_frame_stage` workers;
- each stage owns:
  - one per-stage weight RAM,
  - two output frame banks,
  - a small FSM that reads one pair, multiplies/accumulates/scales, then writes
    the pair result;
- final output reads the last stage frame banks two samples per output cycle.

Important timing counters:

```text
TIME0/TOTAL       full cold/warm run cycle count
TIME1/LOAD        static weight preload cycles
TIME2/COMPUTE     top-level aliases this to input-load cycles in pipeline mode
TIME3/PLAYBACK    final output cycles
TIME4/INPUT_LOAD  raw input-frame load cycles
TIME5/LATENCY     input-frame complete to first output-valid
```

Important recent fixes:

- `busy_o` now includes weight load, input load, latency, stage activity, and
  output playback. Earlier versions only reported busy once internal stages or
  output playback were active, making `STATUS` misleading during preload.
- `red_pitaya_top_LED7_mod.sv` now has a stateful cold-run handoff:

```text
on BNET start:
  if pipeline weights are already loaded:
    pulse sample DDR reader immediately
  else:
    set sample_start_pending

when weight preload finishes:
  if sample_start_pending:
    pulse sample DDR reader
    clear sample_start_pending
```

This was added because the first edge-only handoff still left cold pipeline
runs stuck after stream 1 reached `98304` bytes while stream 0 stayed at `0`.

## Top-Level Mode Selection And DAC Path

`red_pitaya_top_LED7_mod.sv` selects active engine outputs:

```text
if CONFIG[5] && CONFIG[1:0] == 2:
  use butterfly_network_static_pipeline
else:
  use butterfly_network
```

Selected signals include:

```text
sample_ready
weight_ready
butterfly_dat[0:1]
output_valid
busy
done
timing counters
```

Normal two-DAC output:

```text
butterfly_dat[0] -> DAC A -> RF OUT1
butterfly_dat[1] -> DAC B -> RF OUT2
```

Single-DAC mode, `CONFIG[6]`:

```text
cycle 0: DAC A gets y0, DAC B gets 0, y1 is held
cycle 1: DAC A gets held y1, DAC B gets 0
```

This reconstructs the full vector on RF OUT1 over twice as many DAC cycles.
Backpressure (`output_ready_i`) prevents the compute engine from dropping the
second lane while the held sample is emitted.

## Hardware Dataflow Summary

Serial DDR mode, `CONFIG=2`:

```text
BNET:START
  -> start stream 0 reader
  -> start stream 1 reader
  -> serial engine accepts samples and weights
  -> compute all stages serially
  -> output final vector two samples per clock
```

Serial weight-reuse mode, `CONFIG=18`:

```text
first run with CONFIG=2 loads weights
next run with CONFIG=18:
  -> start stream 0 reader only
  -> reuse serial engine weight RAM
```

Static pipeline cold mode, `CONFIG=34`:

```text
BNET:START
  -> start stream 1 reader
  -> preload all static stage weights
  -> start stream 0 reader after weight_load_done
  -> load one 4096-sample input frame
  -> push frame through per-stage workers
  -> output final vector
```

Static pipeline warm mode, `CONFIG=34` with weights already loaded:

```text
BNET:START
  -> skip stream 1
  -> start stream 0 reader immediately
  -> run next input frame with reused static weights
```

## Board-Test Expectations

Serial 2048 mode:

```text
CONFIG?            -> 2
STREAM0:RPTR?      -> 4096
STREAM1:RPTR?      -> 45056
STATUS? done bit   -> set
ERROR?             -> 0
TIME1/TIME2/TIME3  -> nonzero
```

Pipeline 4096 cold mode:

```text
CONFIG?            -> 34
STREAM1:RPTR?      -> 98304
STREAM0:RPTR?      -> 8192
STATUS? done bit   -> set eventually
ERROR?             -> 0
TIME1              -> nonzero weight preload cycles
TIME4              -> nonzero input-load cycles
TIME5              -> nonzero latency cycles
TIME3              -> about VECTOR_LEN/2 for two-DAC output
```

Pipeline 4096 warm mode:

```text
STREAM1:RPTR?      -> should not advance/reload weights
STREAM0:RPTR?      -> 8192 each run
TIME1              -> should remain zero or unchanged for warm input-only runs
TIME4/TIME5/TIME3  -> finite and stable across repeated runs
```

RF loopback expectations:

- In normal two-DAC mode, RF OUT1 carries even-indexed output samples and RF
  OUT2 carries odd-indexed output samples.
- To compare the full BNET result, connect both RF outputs to both inputs and
  interleave captured channels.
- In single-DAC mode, RF OUT1 should carry the full vector in order, but over
  twice as many DAC cycles.

## Bugs And Pitfalls To Avoid

### Soft reset must reset readers and compute state

Symptom:

```text
BNET:RST
BNET:STREAM0:RPTR? -> stale nonzero
BNET:STREAM1:RPTR? -> stale nonzero
```

Preserve:

- `bnet_regs.sv` exports `soft_reset_pulse_o`.
- Top level wires it into both DDR readers and both BNET engines.
- Reader FIFOs/FSMs and compute FSMs include this reset.

### Do not issue overlapping AXI bursts

Symptom:

```text
busy forever
read pointers stop early
bytes_requested_axi runs ahead
```

Preserve in `bnet_axi_reader_ch.sv`:

- `ctrl_req_inflight_axi`
- `ctrl_busy_seen_axi`
- issue one burst, wait until busy is observed, then wait until idle.

### Do not drop AXI read beats at the FIFO boundary

Symptom:

```text
short streams pass
long stream 1 stops early
```

Preserve:

- AXI-clock skid buffer before `asg_dat_fifo`.
- Do not request next burst until skid buffer has drained.
- Keep FIFO reset/start handling synchronized.

### BRAM inference is critical

Large vector and weight memories must infer block RAM. Earlier versions used too
many LUTRAM/F7 mux resources, especially when attempting 16384 pipeline length.

Current practical compile target:

```text
BNET_PIPE_VECTOR_LEN = 4096
```

Preserve `bnet_tdp_ram` style:

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

Review Vivado utilization reports for BRAM/LUTRAM mapping.

### Pipeline cold-run handoff is delicate

Known bad signature from an earlier build:

```text
STATUS?        -> 1
STREAM1:RPTR?  -> 98304
TIME1?         -> nonzero
STREAM0:RPTR?  -> 0
TIME4?         -> 0
```

Meaning:

- static weights loaded;
- sample DDR reader never started;
- pipeline stuck waiting for the input frame.

The current HDL tries to fix this with `bnet_pipe_sample_start_pending` in
`red_pitaya_top_LED7_mod.sv`. Review this logic carefully.

### Weight stream sizes must match engine size

For serial 2048 mode:

```text
weights = 2048 * 11 packed words = 45056 bytes
```

For pipeline 4096 mode:

```text
weights = 4096 * 12 packed words = 98304 bytes
```

Uploading the wrong weight size can leave a reader or engine waiting forever.

## Suggested Review Questions For ChatGPT

When asking another model to review the HDL, give it this file and these files:

```text
prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
prj/v0.94/rtl/bnet_regs.sv
prj/v0.94/rtl/bnet_axi_reader_ch.sv
prj/v0.94/rtl/butterfly_network.sv
prj/v0.94/rtl/butterfly_network_static_pipeline.sv
```

Ask it to check:

1. Does the top-level mode mux correctly isolate serial and pipeline engines?
2. Does DDR stream 0 start correctly for serial, pipeline cold, and pipeline
   warm runs?
3. Does DDR stream 1 correctly skip weight reload when weights are reusable?
4. Can `bnet_pipe_sample_start_pending` miss or duplicate a sample-reader start?
5. Can `STATUS[0]`, `STATUS[1]`, and timing counters get stuck or misreport?
6. Are there any combinational loops or multiple drivers in the ready/valid
   handshakes?
7. Are reset paths complete for soft reset and PS reset?
8. Are BRAMs inferred for all large vector/weight memories?
9. Does single-DAC serialization preserve sample order and apply backpressure?
10. Are the 2048 serial and 4096 pipeline byte counts consistent from software
    through RTL?

## Current Next Steps

1. Recompile the latest HDL after the stateful pipeline cold-start fix.
2. Upload the bitstream to the board.
3. Rerun `../RedPitaya_app/scpi-tests/bnet_pipeline_mode_test.ipynb`.
4. First check the cold pipeline diagnostics:

```text
BNET:STATUS?
BNET:ERROR?
BNET:STREAM0:RPTR?
BNET:STREAM1:RPTR?
BNET:TIME0?
BNET:TIME1?
BNET:TIME2?
BNET:TIME3?
BNET:TIME4?
BNET:TIME5?
```

5. If cold pipeline completes, run repeated warm 4096-frame tests.
6. If warm tests are stable, compare cycle counters for:

```text
serial variable-weight mode
serial static-weight reuse mode
pipeline cold mode
pipeline warm mode
```

