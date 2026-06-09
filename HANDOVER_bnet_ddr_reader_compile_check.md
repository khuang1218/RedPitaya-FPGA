# BNET DDR Reader Hardware Handover

Date: 2026-06-04

Latest board-test update: 2026-06-08

Latest source update: 2026-06-08 later pass

Repository:

```text
RedPitaya-FPGA
```

Target project:

```text
prj/v0.94
MODEL=Z20_G2
Board: Red Pitaya STEMlab 125-14 Zynq 7020 Gen 2
Recommended Vivado: 2020.1
```

## Goal

The current hardware work moves the butterfly network toward the final intended signal path:

```text
ADC or ASG test input or DDR stream input
  -> BNET compute block
  -> DAC output path
```

The new DDR mode uses the two AXI HP ports that normally serve ASG deep-memory generation:

```text
axi2_sys -> BNET stream 0, sample/input data
axi3_sys -> BNET stream 1, packed weight data
```

Normal ASG BRAM/table mode is intended to remain usable for test stimulus. ASG deep-memory mode is intentionally stubbed in this BNET bitstream.

Current important caveat:

- DDR is now board-proven for the fixed `VECTOR_LEN=1024` batch transaction.
- The current source has since been expanded to `VECTOR_LEN=2048`, with
  timing counters and guarded ping-pong auto-swap/auto-restart support. Rebuild
  and board-test this newer source before treating the 2048 path as validated.
- The current hardware still does:

```text
load fixed input/weight buffers from DDR
  -> compute the complete staged network
  -> loop playback to DAC
```

- It is not yet a true continuous streaming architecture. The next major
  milestone is to expand vector size and overlap/refill DDR buffers so the FPGA
  can sustain a higher rate instead of waiting for software to upload a fixed
  buffer and issue one `BNET:START` per run.

## Files Changed

### Modified

```text
prj/v0.94/rtl/bnet_regs.sv
prj/v0.94/rtl/butterfly_network.sv
prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
```

### Added

```text
prj/v0.94/rtl/bnet_axi_reader_ch.sv
```

The Vivado TCL scripts add the whole `prj/v0.94/rtl` directory, so the new source file should be picked up automatically by the normal project/non-project build flow.

## Register Changes

`bnet_regs.sv` still occupies the existing custom BNET sys-bus region on `sys[7]`, which maps to the software BNET base around `0x00700000`.

Existing scalar registers remain:

```text
0x00 CONTROL
0x04 STATUS
0x08 CH0
0x0c CH1
0x10 CH2
0x14 CH3
0x18 CH4
0x1c CH5
0x20 CH6
0x24 CH7
0x28 OUT0
0x2c OUT1
0x30 OUT2
0x34 OUT3
```

New global registers:

```text
0x38 VECTOR_LEN      RW, currently advisory for later software/DDR flow
0x3c STREAM_COUNT    RO, currently 8
0x40 ACTIVE_MASK     RO, one bit per stream, 1 means pong/base1 active
0x44 PENDING_MASK    RO, one bit per stream, swap pending
0x48 ERROR_MASK      RO, one bit per stream, descriptor error
0x4c CONFIG          RW, BNET input source plus ping-pong controls
0x50 TIME_TOTAL      RO, last start-to-done cycle count
0x54 TIME_LOAD       RO, last load-state cycle count
0x58 TIME_COMPUTE    RO, last compute-state cycle count
0x5c TIME_PLAYBACK   RO, last playback cycle count
```

`CONFIG[1:0]`:

```text
0 = ASG test stream: sample=ASG A, weight=ASG B
1 = ADC real-time stream: sample=ADC A, weight=ASG B
2 = DDR stream: sample=stream 0, weight=stream 1
```

Additional `CONFIG` bits:

```text
bit 2 = auto-swap to a valid pending ping/pong buffer when compute finishes
bit 3 = auto-restart after a successful auto-swap
```

Auto-restart is guarded: it only fires when every enabled stream has a valid
pending inactive buffer and no descriptor/runtime error. Software must commit
the next inactive buffer while the current run is still active.

Per-stream descriptor window:

```text
stream n base = 0x100 + n * 0x40

+0x00 BASE0          RW, ping DDR base address
+0x04 BASE1          RW, pong DDR base address
+0x08 LENGTH_BYTES   RW, buffer length in bytes
+0x0c STRIDE_BYTES   RW, byte stride, default 2
+0x10 FORMAT         RW, format tag, currently not interpreted
+0x14 CONTROL        RW
+0x18 STATUS         RO
+0x1c READ_PTR       RO, reader byte pointer/status mirror
```

Per-stream `CONTROL` bits:

```text
bit 0 = enable stream
bit 1 = commit buffer 0 as pending
bit 2 = commit buffer 1 as pending
bit 3 = force swap now
bit 4 = clear descriptor error
```

Top-level `CONTROL[0]` now also emits a one-clock `start_pulse_o` from `bnet_regs`.

## Top-Level Hardware Changes

In `red_pitaya_top_LED7_mod.sv`:

- Added `BNET_STREAM_COUNT = 8`.
- Added wires for BNET input selection, DDR samples, DDR weights, descriptor arrays, and stream enable/active state.
- Added two BNET DDR reader instances:

```text
i_bnet_sample_reader -> axi2_sys -> stream 0
i_bnet_weight_reader -> axi3_sys -> stream 1
```

- Added dummy AXI interfaces for ASG:

```text
asg_axi_a_dummy
asg_axi_b_dummy
```

- Rewired `red_pitaya_asg` so:

```text
axi_a_sys = asg_axi_a_dummy
axi_b_sys = asg_axi_b_dummy
```

This means ASG deep-memory AXI no longer owns `axi2_sys` and `axi3_sys`.

- Added BNET input mux:

```text
CONFIG 0: bnet_sample_dat = asg_dat[0],          bnet_weight_dat = asg_dat[1]
CONFIG 1: bnet_sample_dat = adc_dat[0][13:0],    bnet_weight_dat = asg_dat[1]
CONFIG 2: bnet_sample_dat = DDR stream 0 output, bnet_weight_dat = DDR stream 1 output
```

- BNET output still drives the DAC path:

```text
butterfly_dat[0] -> dac_a_sum -> DAC A
butterfly_dat[1] -> dac_b_sum -> DAC B
```

## New DDR Reader Module

New file:

```text
prj/v0.94/rtl/bnet_axi_reader_ch.sv
```

Purpose:

- Read a ping-pong-selected DDR buffer through `axi_sys_if`.
- Use existing Red Pitaya `axi_rd_burst`.
- Use existing `asg_dat_fifo` async FIFO IP to cross from `dac_axi_clk`/AXI clock to `adc_clk`/BNET clock.
- Emit one signed 14-bit sample per valid output cycle.
- Hold each output sample stable until the top-level asserts `consume_i`.

Important implementation details:

- AXI read data width is 64 bits.
- Each 64-bit beat is split into four 16-bit lanes.
- Each lane currently contributes the low 14 bits as the BNET sample.
- `stride_bytes_i` currently only increments `read_ptr_o`; it does not yet skip data lanes in hardware.
- `FORMAT` is exported but not yet interpreted.
- Reader starts when BNET `CONTROL[0]` is written and `CONFIG[1:0] == 2`.
- The reader requests AXI bursts up to 16 beats at a time.
- In DDR mode, the top-level consumes stream 0 and stream 1 together only when
  both readers are valid. This keeps sample and weight streams aligned across
  ordinary AXI latency/skew.

## Full Staged Butterfly Network Change

`butterfly_network.sv` has been replaced with a staged fixed-point butterfly
engine. It is intentionally serial rather than fully parallel for this first
full-network hardware pass.

Default build shape:

```text
VECTOR_LEN = 2048
STAGE_COUNT = log2(VECTOR_LEN) = 11
PAIR_COUNT = VECTOR_LEN / 2 = 1024 butterflies per stage
TOTAL_WEIGHTS = STAGE_COUNT * VECTOR_LEN = 22528 packed weight words
```

Each packed weight word is still 14 bits:

```text
weight[13:7] = contribution to first butterfly output
weight[ 6:0] = contribution to second butterfly output
```

With the default parameters those are two signed 7-bit Q1.6 weights.

The engine does:

```text
1. Load VECTOR_LEN input samples into bank0 RAM.
2. Load STAGE_COUNT * VECTOR_LEN packed weight words into weight RAM.
3. For each stage:
   - route pairs using radix-2 butterfly addressing
   - read two samples from the current bank
   - read two packed weight words for that stage/pair
   - compute two weighted outputs
   - round back to sample scale
   - saturate to signed 14-bit
   - write into the opposite bank
4. Toggle banks between stages.
5. Play the final vector back to DAC A/B two samples per clock.
```

The module interface changed from one combined valid signal to independent
sample and weight handshakes:

```systemverilog
input  logic sample_valid_i
output logic sample_ready_o

input  logic weight_valid_i
output logic weight_ready_o

output logic output_valid_o
output logic busy_o
output logic done_o
```

Reason:

- A full network needs only `VECTOR_LEN` input samples.
- It needs `VECTOR_LEN * log2(VECTOR_LEN)` weight words.
- DDR stream 0 and stream 1 therefore need different lengths and independent
  consume signals.
- The old `sample_valid && weight_valid` consume rule would force the sample
  stream to contain dummy samples for every extra weight word.

Top-level behavior:

```text
ASG mode: sample_valid_i = 1, weight_valid_i = 1
ADC mode: sample_valid_i = 1, weight_valid_i = 1
DDR mode: sample_valid_i = stream0 valid, weight_valid_i = stream1 valid
```

DDR reader consume behavior now follows the network ready signals:

```text
stream 0 consume = DDR mode && sample_ready_o && stream0 valid
stream 1 consume = DDR mode && weight_ready_o && stream1 valid
```

So for a real full-network DDR test:

```text
stream 0 length = VECTOR_LEN * 2 bytes
stream 1 length = VECTOR_LEN * log2(VECTOR_LEN) * 2 bytes
```

For `VECTOR_LEN=1024`:

```text
stream 0 length = 2048 bytes
stream 1 length = 20480 bytes
```

For the current `VECTOR_LEN=2048` source:

```text
stream 0 length = 4096 bytes
stream 1 length = 45056 bytes
```

`bnet_regs.sv` now receives compute status from the butterfly engine:

```text
STATUS[0] = busy
STATUS[1] = done, sticky until next START/reset
STATUS[4] = output playback valid
```

## Compile Check Required

No Vivado or Verilator compile was run on this PC. Only source-level checks were run.

Run with Vivado 2020.1 on the other PC.

Recommended from repo root:

```powershell
make project PRJ=v0.94 MODEL=Z20_G2
```

or full bitstream:

```powershell
make PRJ=v0.94 MODEL=Z20_G2
```

If using Vivado directly:

```powershell
vivado -nojournal -mode batch -source red_pitaya_vivado_Z20_G2.tcl -tclargs v0.94
```

The current Makefile sets:

```make
MODEL ?= Z20_G2
PRJ   ?= v0.94
```

so a plain `make project` or `make` may also target the right build if the environment is otherwise ready.

## Specific Compile Risks To Check First

These are the places most likely to need syntax or Vivado-version cleanup.

1. `asg_dat_fifo` width mismatch

`bnet_axi_reader_ch.sv` uses:

```systemverilog
logic [96-1:0] fifo_din;
logic [96-1:0] fifo_dout;
```

Existing `asg_dat_fifo` was previously used in `rp_asg_axi` with:

```systemverilog
din = {32-bit addr, 64-bit data}
```

So 96 bits should match, but Vivado/IP should confirm.

2. FIFO reset expression

The reader connects:

```systemverilog
.rst(fifo_rst_axi || fifo_rst_cfg)
```

If Vivado/IP dislikes mixed-domain reset expression directly on the FIFO reset port, split it into a named wire or separate synchronized reset logic.

3. Interface dummy AXI assignments

`red_pitaya_top_LED7_mod.sv` assigns response-side fields on `asg_axi_a_dummy` and `asg_axi_b_dummy`:

```systemverilog
werr, wrdy, rdata, rerr, rrdym, rardy
```

This is intended to satisfy the ASG AXI reader when ASG deep-memory mode is unused. Compile-check that these interface fields are legal to drive at top level and do not create multiple drivers.

4. `bnet_regs` output arrays

`bnet_regs.sv` exports unpacked arrays:

```systemverilog
output logic [STREAM_COUNT-1:0][32-1:0] stream_base0_o
```

Vivado 2020.1 should support this SystemVerilog style, but if it objects, flatten the arrays or export only streams 0 and 1 for the first DDR prototype.

5. `lane_index * 16` part-select

The reader uses:

```systemverilog
sample_o <= word_data[(lane_index * 16) +: SAMPLE_DW];
```

Vivado should support variable indexed part-select. If it does not in this context, replace with a `case(lane_index)`.

6. Updated `butterfly_network` handshake ports

This item is superseded by the full-network interface. There is only one
`butterfly_network` instantiation:

```text
prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
```

Confirm Vivado sees the updated module and these ports:

```text
sample_valid_i, sample_ready_o
weight_valid_i, weight_ready_o
output_valid_o, busy_o, done_o
```

8. Full-network RAM inference

`butterfly_network.sv` now contains:

```text
bank0_ram: 2048 x 14
bank1_ram: 2048 x 14
weight_ram: 22528 x 14
```

Vivado should infer BRAM or distributed RAM. Check utilization. If it maps too
much weight storage into LUT RAM, add RAM style attributes or split weight RAM
by stage.

9. Local declarations and casts in `always_comb`

The staged engine uses SystemVerilog local variables inside `always_comb` and
parameter-sized concatenations. Vivado 2020.1 should support this, but this is a
good first syntax-check target.

7. ASG deep-memory behavior

Expected in this bitstream:

```text
Normal ASG BRAM/table generation: preserved
ASG SOUR#:AXI deep-memory generation: not usable, because axi2/axi3 are owned by BNET
```

If existing software tries to enable ASG AXI mode at the same time, it will talk to ASG registers but the ASG AXI fabric is stubbed.

## Source-Level Checks Already Run

From repo root:

```powershell
git diff --check -- prj/v0.94/rtl/bnet_regs.sv prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv prj/v0.94/rtl/butterfly_network.sv prj/v0.94/rtl/bnet_axi_reader_ch.sv
```

Result:

```text
Passed, with only Git CRLF warnings.
```

Checked there is only one `bnet_regs` instantiation and one `butterfly_network` instantiation.

## Board Debug Findings - 2026-06-08

The first hardware runs exposed two separate DDR-mode bugs.

### Bug 1: BNET reset did not reset DDR readers

Symptom from the notebook diagnostics:

```text
BNET:RST
BNET:STREAM0:RPTR? -> nonzero, for example 1152
BNET:STREAM1:RPTR? -> nonzero, for example 7528
```

Meaning:

- The SCPI/API path was reaching `bnet_regs`.
- The reader read-pointer registers were not being reset by `BNET:RST`.
- This made later smoke-test results ambiguous because stale reader state
  survived across runs.

Root cause:

- `bnet_regs.sv` handled the soft reset internally, but the reset pulse was not
  exported to the DDR readers or `butterfly_network`.

Fix applied:

- `bnet_regs.sv`
  - Added `soft_reset_pulse_o`.
  - Pulses it when `CONTROL[1]` is written.
- `red_pitaya_top_LED7_mod.sv`
  - Added `bnet_soft_reset_pulse`.
  - Wired it into both `bnet_axi_reader_ch` instances.
  - Wired it into `butterfly_network`.
- `bnet_axi_reader_ch.sv`
  - Added `soft_reset_i`.
  - Resets cfg-clock visible state, including `read_ptr_o`.
  - Synchronizes soft reset into the AXI clock domain and resets the AXI-side
    reader FSM/FIFO.
- `butterfly_network.sv`
  - FSM reset condition now includes `soft_reset_i`.

Board confirmation after this fix:

```text
BNET:RST
BNET:STREAM0:RPTR? -> 0
BNET:STREAM1:RPTR? -> 0
```

### Bug 2: DDR reader stopped after partial buffer consumption

After Bug 1 was fixed and the new bitstream was programmed, the smoke test still
timed out. The new diagnostics were different:

```text
Before START:
  pending         = 0x3
  stream0_rptr    = 0
  stream1_rptr    = 0

At timeout:
  status          = 0x1
  pending         = 0x0
  error           = 0x0
  stream0_status  = 0x4
  stream1_status  = 0x4
  stream0_rptr    = 1152
  stream1_rptr    = 7552
```

Expected consumption for the full staged smoke test:

```text
stream 0 = 4096 bytes
stream 1 = 45056 bytes
```

Interpretation:

- `BNET:START` was accepted.
- Pending buffers were consumed.
- Both DDR readers began moving data.
- The readers then stopped early, so the staged butterfly engine stayed busy
  waiting for the rest of the load.
- Increasing the notebook timeout cannot fix this because hardware progress has
  stopped.

Likely root cause:

- `bnet_axi_reader_ch.sv` used `axi_rd_burst.ctrl_busy_o` to decide when it
  could issue another `ctrl_val`.
- In `rtl/classic/axi_rd_burst.sv`, `ctrl_busy_o` is registered from internal
  `axi_busy`, so it is delayed.
- The BNET reader could therefore issue another read request before the
  previous burst's busy state was visible.
- That allowed `bytes_requested_axi` to run ahead of actual delivered AXI data,
  so the reader could believe the full descriptor had been requested even
  though the BNET clock-domain consumer only received a partial stream.

Fix applied in `bnet_axi_reader_ch.sv`:

- Added `ctrl_req_inflight_axi`.
- Added `ctrl_busy_seen_axi`.
- The reader now:
  1. issues one burst,
  2. waits until `ctrl_busy` is observed high,
  3. waits until `ctrl_busy` returns low,
  4. only then allows the next burst request.
- Also connected FIFO `wr_rst_busy` and `rd_rst_busy`.
- Gated FIFO write/read and AXI `rd_drdy_i` while FIFO reset is still busy.

This fix was later verified on board, but it was not sufficient by itself; the
reader still needed an AXI-side skid buffer to avoid losing read data when the
FIFO write side was not ready.

### Bug 3: AXI read data could be lost at FIFO write boundary

Symptom after the burst-handshake fix:

- Stream 0 could complete, but stream 1 still stopped early on longer runs.
- One representative result was stream 0 complete and stream 1 only
  `14032/20480` bytes.

Root cause:

- AXI read data from `axi_rd_burst` was wired too directly into the async FIFO.
- A valid AXI beat could arrive while the FIFO write side was reset-busy or
  full.
- Because there was no intermediate holding queue, that beat could be dropped,
  and the reader would never deliver the complete configured stream.

Fix applied in `bnet_axi_reader_ch.sv`:

- Added a small AXI-clock skid buffer between `axi_rd_burst` and `asg_dat_fifo`.
- AXI `rd_drdy_i` now follows skid-buffer capacity.
- FIFO writes drain from the skid buffer only when `!fifo_wr_rst_busy` and
  `!fifo_full`.
- New debug outputs report skid-buffer ready/count/overflow plus AXI/FIFO state.
- `can_request_axi` waits for the skid buffer to drain before issuing the next
  AXI burst.

Board confirmation after this fix:

```text
Payload sizes: stream0=2048 bytes, stream1=20480 bytes
After START: status=0x12, active=0x0, pending=0x0, error=0x0
Stream 0: status=0x4, rptr 0 -> 2048
Stream 1: status=0x4, rptr 0 -> 20480
```

### Bug 4: RF OUT1 was compared to the wrong PC reference

Symptom:

- The digital DDR test passed, but the first RF multiple-input validation failed
  with ramp correlation around `0.496`.

Root cause:

- `butterfly_network.sv` playback emits two final-vector samples per clock:

```text
DAC A / RF OUT1 = y0 = expected[0], expected[2], expected[4], ...
DAC B / RF OUT2 = y1 = expected[1], expected[3], expected[5], ...
```

- The notebook compared RF OUT1 against the full 1024-sample PC reference
  instead of the even-index OUT1/y0 half.

Fix applied in the software notebook:

- RF OUT1 capture now compares against `expected[0::2]`.
- The RF capture cell prints a direct PC-reference correlation/RMSE/offset.
- The multiple-input stability test uses a 512-sample OUT1/y0 reference window.

Latest board result:

```text
ramp         corr=0.996 rmse=0.090 offset=1154 repeat_delta=nan
sine         corr=1.000 rmse=0.013 offset=1347 repeat_delta=nan
triangle     corr=0.994 rmse=0.110 offset=223  repeat_delta=nan
cosine_mix   corr=0.998 rmse=0.073 offset=1175 repeat_delta=nan
ramp_repeat  corr=0.996 rmse=0.090 offset=1031 repeat_delta=0.003
Multiple-input RF validation and repeat-stability checks passed
```

### Diagnostics still missing

The current public BNET registers show stream read pointers, but they do not
show enough internal reader state to distinguish AXI starvation, FIFO problems,
or compute-side backpressure.

Useful future debug counters/status:

- `bytes_requested_axi`
- delivered AXI beat count
- consumed sample/word count
- `running_axi`
- `ctrl_req_inflight_axi`
- `ctrl_busy`
- FIFO empty/full/reset-busy flags
- butterfly load state, `sample_wr_addr`, `weight_wr_addr`,
  `samples_loaded`, and `weights_loaded`

Current underrun reporting is also weak because top-level `consume_i` is gated
by reader `valid_o`. If the butterfly engine is ready but the reader has no
valid data, `consume_i` is already false, so `underrun_o` may not assert. For a
real runtime starvation flag, either pass the compute ready signal separately
into the reader or create a top-level starvation condition:

```text
DDR mode && compute_ready && !reader_valid
```

### Remaining risks after the reader fixes

- If future larger-vector tests show early pointer stops again, inspect
  skid-buffer overflow, FIFO reset-busy/full, and AXI backpressure first.
- If `stream0_rptr` and `stream1_rptr` reach the expected byte counts but
  `STATUS[1]` does not assert, the likely bug is inside `butterfly_network.sv`
  load/compute FSM rather than the DDR readers.
- Confirm the Vivado hierarchy has only BNET driving `axi2_sys` and `axi3_sys`;
  ASG deep-memory AXI should remain connected to dummy interfaces in this
  BNET bitstream.
- Confirm the `asg_dat_fifo` IP remains 96-bit wide. The checked XCI reports
  `Input_Data_Width=96`, `Output_Data_Width=96`, and `Input_Depth=256`, which
  matches the reader's `{32-bit address, 64-bit data}` FIFO word.

## Current Git Status

Relevant files at handover:

```text
 M prj/v0.94/rtl/bnet_regs.sv
 M prj/v0.94/rtl/butterfly_network.sv
 M prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
?? prj/v0.94/rtl/bnet_axi_reader_ch.sv
```

This handover file itself is also new:

```text
?? HANDOVER_bnet_ddr_reader_compile_check.md
```

## Expected First DDR Test Sequence After Build

After Vivado compile succeeds and software support is added or register writes are done manually:

1. Write stream 0 descriptors:

```text
0x100 BASE0
0x104 BASE1
0x108 LENGTH_BYTES
0x10c STRIDE_BYTES = 2
0x114 CONTROL bit0 enable, plus bit1 or bit2 commit selected buffer
```

2. Write stream 1 descriptors:

```text
0x140 BASE0
0x144 BASE1
0x148 LENGTH_BYTES
0x14c STRIDE_BYTES = 2
0x154 CONTROL bit0 enable, plus bit1 or bit2 commit selected buffer
```

3. Set BNET DDR input mode:

```text
0x4c CONFIG = 2   DDR one-shot
0x4c CONFIG = 6   DDR + auto-swap
0x4c CONFIG = 14  DDR + auto-swap + auto-restart
```

4. Start BNET:

```text
0x00 CONTROL bit0 = 1
```

5. Observe DAC outputs.

## Known Incomplete Items

- The current board-proven design is still fixed-length/batch mode, not true
  continuous streaming.
- Source has been expanded to `VECTOR_LEN=2048`, but that build still needs
  Vivado implementation and board validation before it is considered proven.
- The software/API/SCPI stream descriptors and notebook correctness tests now
  upload `VECTOR_LEN * log2(VECTOR_LEN)` weight words for stream 1.
- `FORMAT` is stored/exported but not interpreted.
- `stride_bytes_i` is only used for read pointer accounting, not actual lane skipping.
- `READ_PTR` is now connected for streams 0 and 1. Streams 2..7 read as zero until additional readers/scheduler logic exist.
- Reader underrun/runtime error is reflected into `ERROR_MASK` and per-stream `STATUS[5]`, but it is not latched. It reflects current reader behavior rather than a sticky fault history.
- The reader currently assumes contiguous 16-bit packed sample lanes in DDR.
- There is still no multi-stream scheduler for streams 2..7.
- The full butterfly engine is serial rather than a one-sample-per-clock fully
  parallel implementation. Use the timing counters for the real source build;
  the older rough 1024-build estimate was about
  `log2(1024) * 512 * 2 = 10240` clocks after loading before multiplier
  serialization.
- DAC playback emits two final-vector samples per DAC clock, one on each output
  channel. It does not yet provide a selectable output formatting/routing mode.

## Next Architecture Milestone: Bigger Vectors and Real DDR Streaming

The current use of DDR proves that the FPGA can read larger raw buffers than the
old ASG BRAM table path and can feed the staged engine correctly. However, it is
still a batch transaction:

```text
software uploads a fixed input vector and fixed weight stream
software commits descriptors
software writes BNET:START
hardware loads, computes, then loops playback
```

This has high end-to-end latency because every run is paced by SCPI/software
setup and status polling. DDR should eventually be used to sustain higher data
rates by keeping buffers filled ahead of the FPGA reader.

Recommended next HDL work:

1. Use and extend hardware cycle counters:

```text
total/load/compute/playback cycles are now implemented
stream0 words delivered
stream1 words delivered
stream starvation/backpressure cycles
```

2. Validate `VECTOR_LEN=2048`, then expand further:

```text
stream0 bytes = VECTOR_LEN * 2
stream1 bytes = VECTOR_LEN * log2(VECTOR_LEN) * 2
```

Check BRAM utilization and timing at 2048 first, then after each size increase.

3. Extend the buffer scheduler:

- guarded ping/pong auto-swap/auto-restart is now implemented for the current
  descriptor model
- ring-buffer read pointers with software write pointers, plus
- consumed-buffer/watermark status so software can refill DDR without stopping
  the hardware.

4. Decide the weight strategy:

- if weights are static, load them once and reuse them across many input
  vectors;
- if weights change per vector, stream them with the input but hide upload time
  behind compute/playback where possible.

5. Overlap phases where possible:

```text
load vector N+1 while computing/outputting vector N
```

The current `butterfly_network` FSM does not overlap load, compute, and
playback. Achieving the intended DDR-rate benefit will require either buffering
between phases or a redesigned pipeline.

## Post-Implementation DRC Note

Vivado implementation reported:

```text
[DRC UTLZ-1] Resource utilization ...
requires 107756 LUT-like cells, only 106461 compatible sites available
```

This means the design was about 1295 LUT-compatible resources over the target
device. The likely cause is large BNET memories being inferred into distributed
RAM/LUT fabric instead of block RAM.

First fix applied:

```systemverilog
(* ram_style = "block" *) bank0_ram
(* ram_style = "block" *) bank1_ram
(* ram_style = "block" *) weight_ram
```

These hints were added in `prj/v0.94/rtl/butterfly_network.sv`. Re-run Vivado
implementation and check whether LUT/distributed-RAM utilization drops and BRAM
utilization increases.

Second fix applied after the same utilization DRC persisted:

```text
The butterfly datapath now uses one shared multiplier across four FSM states:

ST_MUL_A_Y0
ST_MUL_B_Y0
ST_MUL_A_Y1
ST_MUL_B_Y1
```

The previous version computed all four products for a butterfly in parallel:

```text
a * wa_y0
b * wb_y0
a * wa_y1
b * wb_y1
```

The new version serializes those products and accumulates them before
`ST_WRITE`. This should reduce arithmetic fabric/DSP pressure, at the cost of
increasing compute latency. For `VECTOR_LEN=1024`, compute latency becomes about:

```text
log2(1024) * 512 butterflies/stage * 6 clocks/butterfly ~= 30720 clocks
```

That is still short in real time at the Red Pitaya FPGA clock, and it is a much
better first-fit architecture for the Zynq-7020.

Third fix applied after Vivado reported:

```text
[DRC UTLZ-1] LUT as Logic over-utilized
requires 87217 LUT as Logic, only 53200 available
```

This points to RAM or RAM-port muxing being mapped into ordinary LUT logic. The
raw `bank0_ram`, `bank1_ram`, and `weight_ram` arrays were replaced with an
explicit true-dual-port RAM wrapper:

```systemverilog
bnet_tdp_ram
```

The staged engine now drives explicit RAM port signals:

```text
addr_a, din_a, we_a, dout_a
addr_b, din_b, we_b, dout_b
```

and uses a new `ST_LATCH` state after `ST_READ` to account for synchronous BRAM
read latency.

Expected inference:

```text
bank0 vector RAM -> block RAM
bank1 vector RAM -> block RAM
weight RAM       -> block RAM
```

Updated compute latency is about:

```text
log2(1024) * 512 butterflies/stage * 7 clocks/butterfly ~= 35840 clocks
```

Still comfortably small in wall-clock time at the FPGA clock.

## Vivado 2020.1 RAM Inference Fix

Vivado synthesis then failed before implementation with:

```text
Unable to infer a block/distributed RAM for 'ram_reg'
RAM has multiple writes via different ports in same process.
If RAM inferencing intended, write to one port per process.
```

This was not a butterfly-network math problem. The `bnet_tdp_ram` wrapper used
one `always_ff` block for both true-dual-port write ports, and Vivado 2020.1 did
not recognize that as a supported BRAM template. Because the weight RAM is large
(`10240 x 14` bits in the board-proven 1024 build, now `22528 x 14` bits in the
2048 source), Vivado could not safely dissolve it into registers/LUTs.

Fix applied:

```systemverilog
always_ff @(posedge clk_i) begin
  if (we_a_i) begin
    ram[addr_a_i] <= din_a_i;
  end
  dout_a_o <= ram[addr_a_i];
end

always_ff @(posedge clk_i) begin
  if (we_b_i) begin
    ram[addr_b_i] <= din_b_i;
  end
  dout_b_o <= ram[addr_b_i];
end
```

Each RAM port now has its own clocked process, matching the template Vivado
asked for in the synthesis report. Re-run synthesis first and check that
`bank0`, `bank1`, and `weight_ram` infer as block RAM instead of being
dissolved into LUT/register fabric.
