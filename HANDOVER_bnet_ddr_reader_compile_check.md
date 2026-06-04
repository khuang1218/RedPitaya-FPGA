# BNET DDR Reader Hardware Handover

Date: 2026-06-04

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
0x4c CONFIG          RW, BNET input source
```

`CONFIG[1:0]`:

```text
0 = ASG test stream: sample=ASG A, weight=ASG B
1 = ADC real-time stream: sample=ADC A, weight=ASG B
2 = DDR stream: sample=stream 0, weight=stream 1
```

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

## Butterfly Network Change

`butterfly_network.sv` gained:

```systemverilog
input logic input_valid_i
```

Capture only advances when `input_valid_i` is high.

Reason:

- ASG/ADC modes are effectively valid every clock.
- DDR mode can stall because AXI/FIFO data is not guaranteed every clock.
- Without `input_valid_i`, DDR latency would corrupt the captured vector.

Top-level behavior:

```text
ASG mode: input_valid_i = 1
ADC mode: input_valid_i = 1
DDR mode: input_valid_i = sample_valid && weight_valid
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

6. New `input_valid_i` port

There is only one `butterfly_network` instantiation:

```text
prj/v0.94/rtl/red_pitaya_top_LED7_mod.sv
```

Confirm Vivado sees the updated module and port list.

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
0x4c CONFIG = 2
```

4. Start BNET:

```text
0x00 CONTROL bit0 = 1
```

5. Observe DAC outputs.

## Known Incomplete Items

- No Vivado compile/synthesis has been run yet.
- No software API/SCPI has been updated for `CONFIG` or stream descriptors yet.
- `FORMAT` is stored/exported but not interpreted.
- `stride_bytes_i` is only used for read pointer accounting, not actual lane skipping.
- `READ_PTR` is now connected for streams 0 and 1. Streams 2..7 read as zero until additional readers/scheduler logic exist.
- Reader underrun/runtime error is reflected into `ERROR_MASK` and per-stream `STATUS[5]`, but it is not latched. It reflects current reader behavior rather than a sticky fault history.
- The reader currently assumes contiguous 16-bit packed sample lanes in DDR.
- There is still no multi-stream scheduler for streams 2..7.
