# V19 hardware and external build

Target: STEMlab 125-14 Z7020 Gen 2, xc7z020clg400-1, Vivado 2020.1.
Status: source implementation; a routed v19 bitstream and board acceptance are
not established by local elaboration or logic simulation. Do not run Vivado on
this laptop. Build on the user's external build machine.

### Latest routed result and audit-call repair (2026-11-06)

Build `20261106_153052` reached routed reporting and passed timing: WNS +0.017 ns,
TNS 0, WHS +0.006 ns, with zero failing setup, hold or pulse-width endpoints.
The routed DRC report contains warnings and no errors. These margins are small;
retain the reports and qualify both TDC channels on the board. This result
supersedes the failing timing measurements in the historical notes below.

Finalization stopped because the sampler-audit script defined
`tdc_audit_v19_sampler_layout` but invoked its old procedure name. Both the call
and the source generator are corrected. A clean Tcl execution regression checks
all 2048 sampler FFs and rejects bad lanes, discontinuities and missing/unplaced
cells. The actual routed sampler audit remains pending until the helper runs.

With the existing completed v19 project open, finish without resynthesis or
rerouting:

```tcl
source {C:/Users/kairan/vscodeprj/fpgaprj/RedPitaya-FPGA/prj/v0.94/scripts/finish_tdc_v19.tcl}
```

This reopens the completed `impl_1`, reruns structural/layout checks, fresh timing
and DRC reports, and writes `impl_1/red_pitaya_v19.bit` plus
`red_pitaya_v19.bin` only after the gates pass. It does not program the board.
The full build helper uses the same finalization gates for future builds.

### First synthesis review and ASG preservation repair

The 2026-11-04 18:10 synthesis completed but the structural checker stopped the
build before implementation: no waveform RAM remained under ASG chA. The saved
DCP confirms seven RAMB36 primitives under chB and none under chA; its log lists
`Synth 8-223` decloning each chA waveform RAM into chB. Initial RAM inference had
reported seven per channel. This is not accepted as independent A/B storage.
That rejected synthesis used111/140 RAM tiles,34877 LUTs and59043 registers;
these figures do not qualify the repaired source or establish routed fit.

V19 now uses dedicated `red_pitaya_asg_v19.sv` and
`red_pitaya_asg_ch_v19.sv` copies. Register behavior and waveform arithmetic are
unchanged; channel hierarchy is preserved and each waveform memory is explicitly
block RAM with DONT_TOUCH. The original v18 ASG files are unchanged. The checker
requires at least seven waveform BRAM primitives under each channel and still
rejects the old merged netlist. A source-level MMIO regression verifies separate
A/B data, overwrites, table-boundary addresses and amplitude/DC settings. The
disabled DDR reader alone is stubbed for this Icarus regression. Full top
elaboration passes143 sources,0errors/17existing infrastructure warnings.

**Run a full fresh build with build_tdc_v19.tcl. Do not resume the rejected
synthesis checkpoint or bypass the table check.** New synthesis/implementation
must confirm that the preservation attributes keep both tables independent and
that placement/routing meets timing. Output remains red_pitaya_v19.bit.

### Second synthesis review and SPI transmit preservation (2026-11-05)

The15:03 synthesis checkpoint confirms the ASG repair: seven waveform RAMB36s
remain under each channel. The next checker failure found only three SPI output
FFs. Reading the actual EDIF shows SCLK, CS# and LDAC# registers, but MOSI's
IOBUF input is tied to GND and no raw_tx/tx_shift/MOSI data-register names remain.
This checkpoint is rejected; the check must not simply be reduced to three.

The SPI module now preserves its hierarchy and its raw transmit/shift registers.
An explicitly preserved `mosi_pin` FF drives MOSI without adding a cycle. The
IOB and4 ns output-routing constraints include this FF. The checker requires
each of the four output FFs individually plus24 transmit shift FFs and24 raw
transmit shadow FFs. The SPI wire-protocol/timing/readback/busy/reset regression
passes holds1/2/3; full top elaboration passes0errors/17existingwarnings. Actual
register retention and timing must be confirmed by another full external build.
No new v19 bitstream has been generated or hardware programmed here.

### Routed receive-bank repair (2026-11-05, 17:32 build)

The build reached post-route optimization and saved reports in
`tdc_v19_reports/20261105_173214/`. The transmit repair is retained: all four
output FFs and both24-bit transmit banks exist. Both ASG tables retain seven
waveform RAMs. The routed netlist has no MISO settling FFs, receive shift FFs or
receive-result FFs, so this checkpoint is rejected for missing readback logic.
SPI now explicitly preserves both receive banks and marks both settling stages
ASYNC_REG, SHREG_EXTRACT=NO and DONT_TOUCH. Sampling latency and register ABI are
unchanged. Only the first settling-stage D pin is exempt from asynchronous
input timing; the second stage and all ordinary logic remain timed. The checker
requires both stages and24 FFs in each receive bank after synthesis and routing.

The saved routed implementation also fails four real250 MHz setup endpoints:
worst WNS−0.194ns, TNS−0.429ns; hold WHS+0.006ns with zero failures. Violations
are rise/fall encoder leading-count paths and channel2 completion control.
Utilization is117/140 RAM tiles,22365LUTs,50547FFs and9564/13300occupied slices.
These are the rejected route's measurements, not the new source's results.
The build helper now selects supported ExtraTimingOpt/AggressiveExplore place,
physical-optimization and route effort settings. No clock period, timing bound
or ordinary path is waived. Setup/hold gates still prevent bitstream output.
Fresh external synthesis/implementation and readback qualification are required.

## Hardware retained

- Two independent full TDC cores, ID `0x54444313`, default SINGLE input.
  Each retains the v18 250 MHz, 512-tap rising/falling pulse-width samplers,
  online encoders, independent 16384-record finite-burst RAM, fine LUTs, frame
  offset, flags and sparse edge diagnostics. Minimum frame period remains 40 ns.
  Each also retains the legacy 125 MHz event TDC, FIFO, histogram/calibration,
  internal/MMCM stimulus, selectable LVDS input, and reset/input guards.
- One unchanged v18 pulse generator: 2 ns HIGH/period units, one common launch
  marker to both width engines. No 50% duty-cycle requirement in hardware.
- Both ordinary ASG channels and their 16384-sample local waveform tables.
  DDR/deep-memory ASG mode was already inactive in v18 and remains unsupported.
- DAC80516 SPI for OUT0..OUT3, atomic four-weight snapshot and explicit LDAC.
- LED7 heartbeat, housekeeping identity/GPIO, PS/MIO and required clocks.

Scope/ADC sample processing and acquisition, PID, BNET, slow PWM/AMS outputs and
daisy transceivers are absent from the v19 hierarchy. Their local bus regions
acknowledge with zero data and an error indication; old acquisition software is
not compatible with this image. The retained system-bus CDC bridge masks slave
error indications at the PS interface, so later software must validate IDs,
BUSY, configuration readbacks and completion rather than rely on AXI errors.
XADC in the
PS generated subsystem is infrastructure, not a restored scope/AMS engine.
Unused physical differential outputs are safely buffered static levels. The
original v18 top and build helper are retained as a reference, not instantiated.

## Address map

| Block | Base |
|---|---|
| Housekeeping | `0x40000000` |
| Two-channel ASG | `0x40200000` |
| TDC channel 1 legacy registers | `0x40710000` (existing address) |
| TDC channel 1 width registers | `0x40710100` (existing address) |
| Pulse generator | `0x40720000` (existing address) |
| TDC channel 2 legacy registers | `0x40730000` |
| TDC channel 2 width registers | `0x40730100` |
| DAC80516 SPI | `0x40740000` |

Each TDC uses the existing register offsets and readout ABI. Busy/input/LUT/abort
state is independent between cores. Both observe the common pulse period and
launch marker, with independent frame offsets. External return causality and
placement/routing-specific fine calibration must be established for each core.

## E1 wiring (all assigned application pins are LVCMOS33)

| Function | Signal | E1 pin | FPGA pin | DAC80516 pin |
|---|---|---:|---|---:|
| Shared pulse launch | DIO1_P | 5 | H16 | — |
| TDC1 return | DIO2_P | 7 | J18 | — |
| TDC2 return | DIO3_P | 9 | K17 | — |
| SPI SCLK | DIO4_P | 11 | L14 | 4 SCLK/SDA |
| SPI MOSI | DIO5_P | 13 | L16 | 5 SDI/A0 |
| SPI MISO | DIO6_P | 15 | K16 | 19 SDO/A1 |
| SPI CS# | DIO7_P | 17 | M14 | 3 CS/SCL |
| LDAC# | DIO4_N | 12 | L15 | 17 |

Use common GND (E1 25/26) and a 3.3 V DAC VIO with valid AVDD/VIO sequencing.
The DAC RESET pin must be held inactive high externally; FLEXIO must have a
defined inactive board configuration. No FPGA RESET/CLEAR GPIO is assigned.
All reserved input/output pins override housekeeping writes permanently.
E3 LVDS launch/return is retained: TDC1 uses existing DIO17/18; TDC2 uses
DIO15/16. No new E3 daisy clock is created; these are asynchronous timing inputs.

## SPI register interface

All registers are aligned 32-bit accesses. ID at +0 is `0x44414301`. The
sequencer is entirely in the 125 MHz ADC/control clock domain; its SCLK is a
registered output, not a fabric clock. SPI mode is idle-low, SDI changed on the
rising edge, target captures falling edge. CS setup/hold/high are >=24 ns.

| Offset | Meaning |
|---|---|
| `0x04` write | Command: 1=write OUT0..3 then LDAC; 2=load four buffers only; 4=LDAC previously loaded group; 8=raw 24-bit write; 16=raw read with automatic second NOP frame; 32=clear DONE |
| `0x08` read | bit0 BUSY; bit1 reserved; bit2 startup-ready; bit3 known four buffers loaded; bit4 known group applied; bit5 DONE |
| `0x0c` R/W | SCLK period in 8 ns ticks, range 4..250; reset 12 (10.4167 MHz); 5=25 MHz; 4=31.25 MHz maximum supported by this controller |
| `0x10/14/18/1c` R/W | Four unsigned 16-bit weight shadow registers for OUT0..3 |
| `0x20` R/W | Raw 24-bit instruction/address/data frame |
| `0x24` read | Last raw read response; requested register data in bits15:0 |
| `0x28` read | Completed LDAC pulse count |
| `0x2c` read | Completed 24-clock SPI frame count |
| `0x30` read | Sequencer clock in Hz (125000000) |
| `0x34` R/W | LDAC low width in 8 ns ticks, 13..250; reset16=128 ns |
| `0x40/44/48/4c` read | Last four weights applied through this sequencer |

Writes during BUSY, invalid commands, misaligned/unknown addresses, and fast raw
read requests return bus errors without changing the active transaction. A held
bus command executes once. The four weights, clock divisors and LDAC width are
snapshotted before CS goes low. Raw writes invalidate the known-buffer/applied
metadata because arbitrary DAC configuration/data may have changed.

Wait for startup-ready (at least 10 ms after FPGA reset), and independently wait
10 ms after any DAC power-up or reset. The hardware guard does not detect a
later independent DAC power cycle. Configure the DAC using raw writes before
issuing a group command: enable the desired reference, output range, OUT0..3
and synchronous update mode. Enable SDO before readback. This source does not
silently select an analog range or enable outputs at FPGA reset.

Raw read command16 requires period>=16 (<=7.8125 MHz). Readback uses two settling
FFs and the conservative slow clock to accommodate SDO delay and wiring. For
example raw `0x810000` reads DEVICE_ID using the first command plus an automatic
NOP frame. Firmware should verify the device ID and read back its configuration.
Use raw writes to configure all16 channels if needed; the atomic group operation
deliberately addresses only OUT0..3 in this revision.

After LOAD_ONLY completes, other shadow values may be staged; LDAC_ONLY still
applies the saved loaded group. Both channel selection and data are in the SPI
frames; there are no per-channel GPIO selects. Applied metadata confirms issued
transfers/LDAC, not analog settling, correct wiring, or successful DAC readback.

At25 MHz, four frames need3.84 us of clocking plus CS/state overhead. There is
no waveform-sequence RAM, FIFO stream or autonomous 100 kHz host feeder in this
revision. The CPU register interface prepares/starts groups. Future software
must measure sustainable update rate; do not equate SPI wire bandwidth with
SCPI/Ethernet throughput. LDAC application is sequencer-timed after a command,
not automatically synchronized to the shared measurement pulse. Coordinate
settling/measurement in the later control flow. No analog settling delay or
matrix delay is assumed or inserted into the TDC measurement path.

## External Vivado build

In the existing project Tcl console, source the FPGA repository helper:

```tcl
source C:/Users/kairan/vscodeprj/fpgaprj/RedPitaya-FPGA/prj/v0.94/scripts/build_tdc_v19.tcl
```

Use the corresponding repository path on the external machine. The helper
archives existing impl_1 artifacts, imports byte-verified project-local sources,
selects red_pitaya_top_v19.sv, disables old application XDCs and installs a
complete v19 pin/clock/TDC/pulse/SPI constraint set. Generated PS/IP constraints
remain with their IP. It resets stale runs, synthesizes, checks all six carry
chains and both ASG buffers, implements using a supported performance strategy,
finishes optional post-route optimization, and audits all four width samplers.

All ordinary capture, encoder, arithmetic, memory, output and reset paths remain
timed. Only intentional asynchronous tap inputs and first settling stages are
excluded; held-payload mailboxes keep their existing4 ns /8 ns bounds. Old broad
root-clock exclusions are not carried into the v19 pin constraints. This may
expose real previously masked infrastructure paths; fix them rather than adding
blanket exceptions. SPI output routing has a4 ns maximum to preserve its clocked
protocol budgets, assuming <=2 ns differential PCB/cable skew; qualify actual
wiring at the selected speed.

Reports/checkpoint are saved in `tdc_v19_reports/<timestamp>/`, including global
and hierarchical utilization, timing, exceptions, DRC, CDC and I/O. Bitstream
generation requires nonnegative setup/hold, no error-severity DRC violations,
and passing sampler/structural audits. Review CDC and all report warnings. The
output is `impl_1/red_pitaya_v19.bit` with its binary companion
`red_pitaya_v19.bin`, as requested on 2026-11-04. Any bootgen BIF must reference
`red_pitaya_v19.bit` explicitly. This supersedes
the earlier v19 output-name preference. Nothing programs the board automatically.

Use fresh RISE/FALL LUTs for each v19 channel; v18 LUTs do not qualify this route.
Verify simultaneous bursts, all flags, odd-HIGH/duty settings, reset/abort and
readback, and SPI/LDAC electrical timing before accepting performance.

## Required later software work

**Remove the artificial 50% duty-cycle restriction.** Frequency and HIGH/duty
must be independent settings with actual quantized readback. Retain genuine
limits: 2 ns pulse resolution, >=40 ns TDC frame period and characterized >=8 ns
input HIGH/LOW. Frame offsets/return windows must match actual PCB timing.

Add channel-aware APIs/SCPI/notebooks for both TDC bases and independent LUTs,
SPI configuration/raw readback/four-weight load/apply, plus settling coordination.
Remove initialization and advertised commands for deleted scope/PID/BNET/AMS/
daisy functions. Retain the two ordinary ASGs and pulse commands. No API/server
or executed measurement notebook is changed by this hardware task.
