# CARRY4 TDC integration and register map

This block is instantiated by `red_pitaya_top_LED7_mod.sv` for `Z20_G2` builds.
It coexists with BNET and the GPIO pulse generator in system-bus slot 7.
Current workspace setup, validation and next actions are in the
[master handover](../../../../../RedPitaya_app/HANDOVER.md).

**Current source interface V18 (SINGLE reset default and targeted timing repair):** the `TDC:WIDTH:*` path measures PCB HIGH pulse
width in finite bursts. It uses the actual pulse_gen cycle marker and a
separate 250 MHz rising-polarity carry samplers for the two pulse edges. The legacy commands/registers below retain
their earlier launch-to-rising-edge meaning. Use the new width procedure for
the PCB's voltage-dependent output duration.

## PCB pulse-width acquisition (V18 / PWB v1, 16384 records)

### V18: retain V17 capture, repair launch/control timing

ID **0x54444312 / VERSION18**. FPGA reset now selects **SINGLE / DIO2_P**;
LVDS remains explicitly selectable. Soft reset still preserves the selection.
The V17 250 MHz sampler, 40 ns minimum frame, encoder, LUT arithmetic, 16384
record capacity, offsets and six-field ABI are retained. Existing V16/V17
minimum-period/diagnostic API and SCPI commands remain compatible.

V17 demonstrated a selected 16384-pulse calibrated 25 MHz burst (655.36 us),
but needed five starts. Its accepted burst had 305 ps SD and +2.45 ns nominal
width bias; short-pulse means shifted by over 2 ns between starts. This is
finite-burst functionality, not accurate continuous streaming qualification.
V17 routed timing still failed: WNS -0.308 ns, 11 setup endpoints, no hold
failures. Small burst SD and passing LUT arithmetic do not remove those limits.

V18 separates ODDR-only data registers from fabric marker feedback, registers
two terminal-comparison halves, and predecodes the minimum-period mailbox seed.
The logical pulse/marker latency is unchanged. After the first V18 route,
the pulse HIGH comparison was split into parallel byte groups to shorten the
remaining phase-to-output path. The initial 2.5 ns ODDR placement target was
removed: SAME_EDGE captures both D inputs on a rising edge, and their real
setup/hold checks now use the 250 MHz clock, including clock skew and jitter.
There is no ODDR data timing exception. The new seed uses the documented
request-held mailbox bound.
Targeted MAX_FANOUT hints address WIDTH state, dispatch and staging routes.
No carry/encoder/width-math redesign or global clock-pair exception was added.

Build externally with `scripts/build_tdc_v18.tcl` in the existing project, or
refresh sources using `scripts/refresh_custom_sources.tcl` and rebuild manually.
The V18 build helper archives prior reports/bitstreams, saves new timing/CDC/DRC
reports, and stops before bitstream generation if setup/hold timing is negative.
No V18 timing-closure or hardware-accuracy result is claimed until that build
and the new `tdc_rigol_v18_25mhz_characterisation.ipynb` run complete. Collect
fresh RISE/FALL LUTs for the new implementation; do not assume V17 tables apply.

### V17: 25 MHz frame initiation and V16 timing repairs

ID **0x54444311 / VERSION17**. The sampling clock remains250 MHz, coarse tick
4000 ps, capacity16384, and all six result fields/PWBv1 unchanged. Hardware
minimum at0x144 is **40 ns /25 MHz**, meaning one new frame every10 clocks.
Total decode/result latency is longer than one frame and is explicitly drained
before completion. Full-capacity periods span655.36 microseconds; acquisition
is a finite burst, not continuous streaming/readout.

The supplied V16 route (October22,23:10:12) failed WNS-0.635 ns/TNS-17.879 ns,
198 setup endpoints,0 hold.184 failures were in the250 MHz domain, with worst
paths from encoder shift registers into32-lane chunk prefix/population logic.
Four125 MHz ASG pointer endpoints and ten asynchronous recovery endpoints in
the pulse generator also failed. PS AXI200 MHz now passed with+0.050 ns WNS.
This is V16 evidence; no new V17 routed timing is available.

WIDTH now uses two `tdc_population_pipeline` encoders. Each binary-tree level
is registered; default512-tap latency is12 clocks and the encoder can accept a
snapshot every clock. Raw population, three-tap majority validation, <=8-tap
transition span, saturation/status flags and rank meaning are preserved.
Legacy launch-to-return commands retain the iterative encoder unchanged.

Raw-frame dispatch is independent of result processing. Four queued raw slots
are released after dispatch; metadata follows encoder validity through the
fixed-latency pipeline. The nine-clock signed width arithmetic accepts a new
decoded frame every10 clocks. Ring overflow, missing/extra encoder completion
or result overlap fails with DONE|OVERFLOW and publishes no records. Abort,
clear, source changes and rearm flush in-flight validity; the drain fence covers
all results and bank-local writes. Sparse diagnostic ticks remain available.

The pulse generator now has an active-high asynchronous ODDR reset FF directly
connected to R, removing the failing inverter path. Internal fast controls use
a synchronous local reset leaf. ODDR asynchronous LOW and GPIO release on clock
loss/reset remain. Only external reset assertion into the synchronizer PRE/CLR
pins is exempt; functional reset release/ODDR R is timed. ASG pointer addition
uses8-bit carry-select groups with a logarithmic group-carry prefix, preserving
the exact combinational sum and pointer-cycle behavior. All are timing repair
candidates; new routed timing, DRC, CDC, resource use and sampler placement must
be checked externally. Additional tree registers/routing may affect placement.

Minimum HIGH/LOW>=8 ns remains a sampled-level/coarse contract, not guaranteed
fine interpolation. Fine validity also depends on line propagation history:
an8.2 ns test pulse was rejected by the ideal10.24 ns full-chain model. The
validator was retained. Initial25 MHz fine qualification uses12..28 ns HIGH,
with both HIGH/LOW longer than the ideal test line. Actual routed/PVT delay
coverage and hardware narrow-pulse performance require measurements.

V16 API/SCPI already reads the minimum dynamically; **no new API ABI or SCPI
commands are required**. VERSION? returns17 and MINIMUM:PERIOD? returns40 with
the new image. API/actual-parser tests cover40 ns ARM/watchdog,36 ns rejection,
and unchanged sparse diagnostics. The existing V16 notebook remains intact.
Use the separate app notebook `tdc_rigol_25mhz_characterisation.ipynb`, which
expects17, requires40 ns, keeps all calibration/integrity gates and records
fresh25 MHz coarse/fine repeats, duty/rate coverage and full-capacity bursts.
It first collects fresh LUTs using the established~1 MHz calibration settings;
fresh25 MHz captures then test rate transfer. Enter the new routed WNS and
restart the kernel; do not assign V16 WNS to V17 or reuse V16 LUTs.

Offline checks passed: full16384-record512-tap40 ns acquisition with fine
correction, all record addresses and256 sparse timestamp pairs; exhaustive
16-tap encoder reference and17/512-tap patterns; consecutive encoder launches
and reset flush; controller faults/overflow/abort/boundaries; legacy TDC;
pulse restart/clock-loss reset with vendor ODDR; and independent ASG addition
equivalence. These verify logic in ideal models, not physical precision,
absolute bias, timing closure or demonstrated hardware25 MHz operation.

Historical sections below describe the earlier versions, not the active source.

### V16 throughput and timing repair (source; implementation pending)

ID **0x54444310 / VERSION16**. At the unchanged 250 MHz sample clock,
both WIDTH encoders scan 32 taps per clock (16 scan clocks for 512 taps).
The conservative scan-plus-processing budget is 49 fast clocks; the hardware
minimum frame is 50 clocks / **200 ns / 5 MHz**. Larger parameterized scans
increase the minimum. This is finite-burst acquisition, not continuous readout.
HIGH and LOW each need at least 8 ns for reliable sampled-level edge detection.

V15's routed `last_one_end -> transition_span_ok` path failed by 12 ps.
V16 registers the span subtraction before comparison, adding one processing
clock without relaxing the <=8-tap transition validity rule. The two 200 MHz
PS AXI converter setup failures (-23/-5 ps) remain timed and require new routed
verification. No timing exceptions, sample/capture alignment or width formula
were changed. Do not claim timing closure or improved physical precision from
simulation. Recalibrate both edge LUTs after routing; broad distributions and
narrow-pulse bias are still unresolved measurement issues.

Sparse timestamps save both 32-bit internal sample ticks every 64 records,
including record index0, across the entire burst (256 pairs at capacity).
This adds 16384 diagnostic storage bits (64-bit ports may use one RAMB36), rather than
widening every result. Check actual resource use after synthesis.
The six-field width record ABI is unchanged. A VALID pair must satisfy
`(fall_ticks-rise_ticks) mod 2^32 == coarse_ticks`. Invalid pairs are diagnostic
only; use flags before interpreting them. Reconstruct relative edge motion as
`unwrapped_ticks*4000 - edge_LUT[raw]`, then subtract nominal elapsed frames.
This is internal timing, not an independent calibrated pin-arrival reference.
Sparse samples can miss fast excursions; retain full width distributions.

Rebuild API first and then the statically linked SCPI server. New commands:

- `TDC:WIDTH:MINIMUM:PERIOD?`: hardware minimum frame period in ns (200 default).
- `TDC:WIDTH:DIAGNOSTIC:CONFIG?`: `stride,capacity` (64,256 default).
- `TDC:WIDTH:DIAGNOSTIC:EDGE? start_sample,count`: 1..128 sparse samples/query,
  rows `cycle_id,rise_ticks,fall_ticks` separated by semicolons. Sample index
  s selects width record index s*64, with cycle_id=s*64+1. Only completed idle
  records may be read; range, read-ready and sequence checks remain active.

The notebook now defaults to V16 with unknown WNS, extends common-rate coverage
through 5 MHz, checks sparse tick/coarse association, and repeats drift tests
without selecting on precision/bias. It keeps matched source/frame periods and
all calibration/integrity gates. V14/V15 remain explicit helper options with
their 500 ns minimum and no new diagnostic commands. Historical notes below
describe their original builds and do not override V16 behavior.

### V15 command-control timing repair (source only)

ID **0x5444430f / VERSION15** distinguishes this repair from the loaded V14.
The supplied October22 11:42 V14 routed report has WNS **-0.039ns**, TNS
**-0.322ns**, 14 setup failures and no hold failures. All setup failures are
in the 250MHz WIDTH domain; the ten detailed paths include request toggle/seen
decode to `completed_fast` reset and `record_write_data` enable. These are
ordinary timed paths, not exempt asynchronous carry measurement inputs.

V15 registers start/abort command decoding before the wide control fanout,
with self-inhibit to consume each mailbox toggle once. It adds one fast clock
to command acceptance. Raw sample pipelines, edge timestamps, frame offsets,
LUT arithmetic, 500ns minimum frame and ABI are unchanged. No timing exception
is relaxed. This is a timing repair candidate, not a routed-closure result or
an established cure for broad width distributions. Rebuild externally and
inspect full timing/CDC/DRC before loading; do not run Vivado on this laptop.
Retain the working V14 image and recalibrate both LUTs after any new route.
The notebook remains configured for loaded V14; explicitly change its expected
version to15 only after deploying and identifying the new image.

### V14 fixed frame offset (retained interface and implementation history)

V14 starts from the **v12-timing-r1** image whose October21 routed report met
all specified timing constraints: WNS+0.031ns,0setup/hold failures,WIDTH250MHz
group setup+0.110ns. That result belongs to the preserved baseline, not V14.
Its source, routed checkpoint, bitstream and report are saved in the app
workspace at `build/hdl-review/20261022-v14/passing-v12-source/` and
`passing-v12-build/`. V13's controller/record-format redesign is not restored.

**V14 ID:0x5444430e, VERSION14.** Six-field records/PWBv1 and fine arithmetic
use the v12 layout. The existing 512-tap RISE/FALL samplers, population encoders,
result buffers,250MHz sampling,16384capacity and500ns minimum frame remain.
BNET stays excluded; single-ended input is the current focus, LVDS deferred.

`TDC:WIDTH:OFFSET ns` / `TDC:WIDTH:OFFSET?` configure/read a fixed acquisition
frame shift. Value is an integer multiple of4ns,0..262140ns,and must be
**strictly less than the launch period**. Set the pulse period before OFFSET;
configure only while WIDTH idle. FPGA reset defaults to0. The API and HDL ARM
both check the period bound. A timer overrun returns DONE|RATE_ERROR with no
published records. CAPTURING includes waiting for the first shifted marker.

Frame n is the full interval from delayed marker n to delayed marker n+1.
Both markers are delayed by the same configured amount; AWG period = FPGA
launch period = acquisition frame duration. The output pulse timing is not
shifted. Zero keeps launch-aligned framing. Place the shifted boundary in LOW
with margin before the earliest RISE and after the latest FALL. Example only:
T1004ns,RISE800ns,FALL1500ns,OFFSET600ns -> frame[600,1604),width700ns.

This remains a single-frame capture. Boundary-cut/missing/extra-edge records
stay invalid; it does not retain a pending RISE across a shifted boundary.
Correct launch association requires the causal PCB/trigger and known cycle
latency, not just an independent AWG with matching frequency settings. Fixed
offset compensates stable delay; clock drift or source restarts can change
phase. The Rigol helper still restarts sources and uses its INT reference, so
OFFSET alone does not synchronize that setup. Scope alignment must apply to
the actual acquisition. The user-authorized bench workflow may restart zero/partial
bursts until complete, retaining all attempts. Never select/retry by width error
or jitter; selected-burst completion does not establish unconditional efficiency.

#### Timing structure and deployment

- `tdc_frame_delay.sv` replaces the original second marker FF with a registered
  marker output. Offset0 has the same marker sampling latency. Raw edge/sample
  pipelines and fine/coarse timestamp differences are not retimed.
- The bus precomputes offset-2 and zero/one special cases. A 16-bit timer uses
  byte increments, a registered carry and two independent registered8-bit
  equalities. Offset1 is explicitly seeded. No timer equality or arithmetic
  feeds the capture state combinationally. One pending actual launch is delayed;
  no free-running marker generator or raw-vector delay memory is added.
- Held configuration transfers directly into local fast-clock registers. The
  offset<period comparison is registered before ARM; no subtract/compare chain
  is inserted in the controller. Existing mailbox4ns maximum delays are kept
  and extended to these new registers. No clock or exception is relaxed.
- New API: `rp_TdcWidthSetFrameOffset` / `rp_TdcWidthGetFrameOffset`. Build and
  install the updated API/header before rebuilding the statically linked SCPI
  server, then deploy both with the new FPGA image. The experimental v13
  DELAY/LATENCY commands are now gated to VERSION13 and reject VERSION14.
- Register0x158 is OFFSET_NS, idle RW;0x15c is read-only feature signature
  **0x46524d01 (FRM v1)**. The experimental v13 registers0x14c/150/154 are not
  implemented on this v12-derived image. Software checks the capability.
- API ARM watchdog allows two periods plus128ns, covering first-launch wait
  and a legal offset<T. For direct register access, choose TIMEOUT accordingly.
- Notebook controls: `FRAME_OFFSET_NS` and optional
  `FRAME_OFFSETS_BY_PERIOD_NS={common_period_ns:offset_ns}`. Defaults0. Every
  capture programs/readbacks/logs the applied offset. Frequency/width tests keep
  equal periods and all original qualification gates. Moving frame boundaries
  does not establish fine input-phase coverage or require new LUTs by itself;
  a new placed/routed image requires fresh RISE/FALL LUT calibration.

Refresh imports the new timer with all TDC dependencies into Vivado's own
project directory and verifies bytes. Inspect new synthesis/route timing,
sampler layout,CDC/DRC and resource use. Static compilation cannot guarantee
that the previous small positive timing margins will survive implementation.
No Vivado is run on this laptop.

### Historical v12 rollback and targeted timing repair

The v13 implementation regressed to WNS -1.997 ns and 6067 failing endpoints.
The saved v12 build had WNS -0.071 ns, TNS -0.159 ns, six setup failures and
zero hold failures. Those six endpoints were two scope-decimator paths and
four ASG pointer paths. V13 source is archived in the application workspace:
`build/hdl-review/20261021-v12-return/preserved-v13/` with source hashes.

At that rollback, the TDC capture and register sources were restored byte-for-byte from
the saved pre-v13 copies. The fine encoder, carry chains and sampler placement
constraints retain v12 behavior. ID is **0x5444430c**, VERSION **12**, PWB ID
**0x50574201**. Six-field records, capacity, 500 ns minimum frame and 250 MHz
sampling remain unchanged. BNET stays disabled. AWG period = FPGA launch period
= acquisition frame duration remains the operating contract.

Only two non-TDC datapaths are changed from that baseline:

- `rp_decim.v` registers decimation/averaging settings locally to remove the
  remote configuration mux from the comparator/accumulator path. Configure
  before ARM and allow one ADC clock to settle. Sample/valid pipeline is unchanged.
- ASG computes the same next/wrapped pointers using a combinational carry-save
  reduction and short carry-select adders. The identity is
  `p + step - size - 1 = p + step + ~size` modulo the original pointer width.
  No cached wrap step or extra clock is used; live configuration, trigger,
  pointer enable and start/wrap/stop priorities retain their v12 meanings.

No clocks, max delays, false paths or multicycle allowances are relaxed.
The source label is **v12-timing-r1**; interface VERSION alone does not identify
a placed image. New routed WNS is unknown until external implementation.

V12 again rejects a pulse cut by a frame boundary. It has no v13 programmable
return bounds, cross-frame pairing, or coarse launch-to-RISE register. Delay/
synchronization support is deferred. The notebook defaults to VERSION12,
keeps equal periods, and makes no v13-only commands on v12. Existing v12 API/
SCPI works; the optional v13 API functions in source are version guarded.
Partial-yield captures remain diagnostic, not evidence of lossless operation.
Use fresh fine LUTs for any new placed/routed image.

Refresh copies all changed files into Vivado's own project directory and
verifies their bytes. Static compilation does not establish timing closure;
inspect the new routed report and sampler layout before hardware calibration.

### V12 bounded population encoding and timing repair (pending implementation)

The October 21 v11 regional reports confirm correct carry/FF colocation and
normally timed sampler-Q pipelines. They also show local data-arrival reversals:
RISE 82/83 = 11.674/11.560 ns and FALL 170/171 = 14.194/14.080 ns in slow/max
reports, with identical sampling-clock delay for each pair. Fast/min reports
also show reversed order (25 ps for those pairs). These are corner-model bounds,
not measured silicon delays, and do not uniquely determine the hardware code.
They support removing the assumption that physical tap numbers are strictly
ordered thresholds. V11's rejects repeat at prefix indices 2 modulo 4.

V12 enables `MAX_TRANSITION_SPAN=8` on both WIDTH encoders. Fine index now means
**the number of raw one bits**, not the leading-one count after majority filtering.
For a single edge with fixed per-tap thresholds, this population rank increases
with propagation time even when adjacent thresholds are reordered. Counting raw
bits avoids merging bins through majority correction. An eight-lane balanced
chunk tree and registered accumulation retain the existing eight-taps/clock scan.

The majority filter remains a pattern validator. A filtered zero-to-one reversal
is corrected only if the region from the first filtered zero through the last
filtered one is at most eight taps wide. Repaired results carry VALID and
BUBBLE_CORRECTED; wider regions retain MULTIPLE_TRANSITIONS without VALID.
Raw all-zero/all-one rejection remains. This bound targets local reordering and
does not certify that every accepted pattern represents one physical edge.
WIDTH adds one final decision clock; the default 64+32-clock processing budget
and 500 ns frame minimum remain. The legacy launch-to-return encoder stays in
its default strict mode with unchanged index semantics and encoding latency.

Other source timing repairs from the complete 129-endpoint report:

- Legacy histogram read, increment and write are pipelined, with forwarding for
  consecutive updates of the same bin. Clear cancels pending updates. Calibration
  completion is published after the final update has drained through the existing
  arithmetic states. Histogram debug reads remain asynchronous.
- WIDTH timeout equality is registered as two independent 16-bit comparisons;
  their AND preserves timeout/restart cycles. Processor launch uses the existing
  small staging occupancy instead of comparing wide acquisition counters.
- ASG computes its next pointer unconditionally and gates pointer feedback at
  the register, removing `dac_do` from the long arithmetic path. Start, wrap,
  stop and sample-step behavior are preserved. Refresh includes this shared file.

VERSION is **12**, ID **0x5444430c**. Register/record packing, capacity and SCPI
commands are unchanged; no API/server rebuild is required. The notebook source
guard now expects v12 and retains historical outputs until rerun. Start a fresh
kernel and collect new RISE/FALL histograms and LUTs for the new encoding and
placement. Old LUTs and v11 prefix-to-physical-tap interpretations are invalid
for v12. Host 99% validity, missing-code, integrity and fresh-validation gates
have not been relaxed.

Static full-top Slang compilation passes (138 sources, DISABLE_BNET, real
primitive declarations, generated PS/IP external): 0 errors / 33 existing port
warnings. No behavioral simulation, live instrument commands or Vivado run has
been performed for v12. Physical accuracy, resource fit, inferred memories and
timing closure require implementation/hardware verification. Two generated
PS/XADC failing endpoints have not been edited; ASG and other paths must also
be reassessed after routing. The last measured WNS remains **-0.437 ns**.

### V11 local sampler layout repair (historical)

The loaded v10 image improved routed WNS to -0.487 ns with 131 failing setup
endpoints, but RISE fine validity regressed to 92.63%. Valid RISE codes were
84..294 instead of approximately 1..214; most rejects returned the diagnostic
prefix index 2. This is consistent with displaced or badly skewed early sampling
taps relative to tap-0 edge detection. The exact routed cause has not yet been
confirmed with Vivado placement/timing queries. Constant LUT/index shifts are
not an accepted repair of those rejected phases.

V11 makes physical sampling locality a mandatory implementation constraint:
`tdc_width_sampler_layout.xdc` defines separate XDC macros for the RISE and FALL
width chains. Each macro has 128 consecutive CARRY4 slices, with CO0/CO1/CO2/CO3
samplers at AFF/BFF/CFF/DFF in the same slice. The placer chooses legal absolute
origins independently; no device coordinates or clock delays are guessed. The
flat constraint intentionally targets the default 128-carry/512-tap hierarchy;
regenerate it for a different size. Existing explicit LOCs, if any, must agree
with its geometry. Do not omit this new XDC when copying the v11 source set.

The first reset-free raw pipeline stage now isolates physical sampler Q outputs
from frame/edge-control logic. Edge detection and HIGH-level checks use that
stage, which is the only functional load of sampler Q. Raw data receives a third
stage before the two-cycle memory-write control pipeline consumes it. The frame
marker receives the same additional clock. RISE/FALL coarse timestamps move by
the same one clock, preserving their difference, snapshot alignment and boundary
semantics. This adds 1024 data FFs for two 512-bit banks, with no raw-buffer or
result-capacity increase. The v10 parallel encoders and 500 ns frame target remain.

VERSION becomes **11**, ID **0x5444430b**. The API/SCPI wire format is unchanged;
no API/server rebuild is required. The notebook now requires v11 and fresh RISE
and FALL density collection. Missing-code and validity gates are unchanged.

Refresh with `scripts/refresh_custom_sources.tcl` to import and verify project-owned
copies of both RTL and XDC, then reset/rebuild. After placement/routing, source
`scripts/audit_tdc_width_sampler_layout.tcl`; it exports all 1024 sampler locations,
checks carry continuity and exact FF colocation/BEL, and fails on mismatches or
an unplaced design. It can also audit v10 before rebuilding. This is read-only
and does not modify the opened design. Run timing/DRC/CDC/utilization acceptance
as well; good placement does not guarantee thermometer monotonicity or accuracy.

Initial static Slang component compilation passed with 0 errors / 0 warnings
(vendor primitives external; default 1ns/1ps). The October 21 prebuild review
below adds behavioral checks. Actual macro legality, routed timing and calibration
recovery remain unverified.

### October 21 consolidated V11 prebuild review

The pending image keeps VERSION 11 and the existing API/record layouts. Further
source changes address paths present in the v10 routed report:

- Width completion now registers `drain_ready` before driving completion/state
  logic. It still waits for both final result-write stages before acknowledging.
- A `CHECK_RANGE` state registers coarse/fine 32-bit range decisions before
  result flag and write-data decoding. Explicit signed fine correction remains.
- Pulse generation registers its terminal comparison one output pair early,
  removing the wide equality from the 250 MHz phase increment/reset feedback.
  The new immutable `prelast` mailbox word is included in the existing bounded
  bundled-data crossing constraint. The 4 ns minimum period is handled explicitly.
- The shared daisy TX selector now assigns idle outputs for reserved modes 6/7;
  its previous incomplete combinational case inferred storage. Unused E3 parallel
  TX inputs and the housekeeping diagnostic input now have explicit zero drivers.
- The refresh helper imports the shared daisy source as a verified project-owned
  copy. Both build entry points exclude BNET constraints when BNET is disabled.

Offline checks passed: signed/frozen-LUT width processing, boundary RAM writes,
abort/rearm/overflow/watchdog, legacy TDC isolation, and pulse output with both
portable and Xilinx ODDR models. A 512-tap/32-record burst passed at 500 ns frames;
this ideal-tap test checks capture/processing, not physical fine accuracy. Pulse
checks cover odd HIGH durations, 8/16-bit counter rollovers and the 4 ns minimum.
Bus transaction hold times 1/2/3 passed. An extracted exact-source selector test
reproduced the old reserved-mode latch behavior and passed after the repair.

Full-top static compilation passed with 138 sources, real primitive declarations,
DISABLE_BNET, and generated PS/IP treated as external: 0 errors / 33 warnings.
Remaining port warnings were reviewed; interconnect clock/reset ports are driven
by interface assignments, and other flagged ports are unused diagnostics or
unused wrapper outputs/inputs. This is not vendor IP elaboration or CDC signoff.
Tcl structural completeness and both 640-cell macro definitions were checked.
No Vivado, full-16384-record simulation or hardware commands were run. Logs and
source hashes are in the app workspace's
`build/hdl-review/20261021-prebuild/review_summary.json`.

The last routed WNS is still -0.487 ns; these source edits do not establish a new
WNS. Smaller ASG/PDM/legacy timing failures also require assessment in the next
implementation. Run the sampler placement audit and routed timing/DRC checks
before accepting that image, then repeat fine calibration with fresh captures.

### V10 timing and parallel processing changes (historical)


The October 20 v9 routed build failed setup timing: WNS -0.862 ns, 4074 failing
endpoints. Its worst paths included the width calibration RAM to `fine_delta`
(-0.862 ns), the legacy tap-bank event reduction into controller/arithmetic
control (-0.793 ns), and the pulse-generator mux into ODDR D2 (-0.764 ns).
V10 addresses those source paths; a fresh implementation must establish whether
all setup/hold/CDC/DRC requirements pass. No timing exceptions are relaxed.

- Width RISE/FALL now use `i_rise_encoder` and `i_fall_encoder` concurrently,
  each scanning eight taps per fast clock. The 512-bit edge selector is removed.
  The three-tap majority filter, leading-one index and malformed-code rejection
  remain the same. This is a throughput change, not a repair of physical tap order.
- Calibration RAM outputs gain separate preserved local fabric registers. The
  17-bit signed LUT difference is computed with registered low-byte borrow and
  high-byte subtraction. The extra states match the RAM-read latency.
- Result readout explicitly sign-extends the stored 17-bit difference to 32 bits.
  V9 hardware reported negative corrections +131072 ps too large after calibration;
  the v10 correction also uses explicit sign extension in the internal 45-bit sum.
- The legacy 512-tap event reduction is registered in groups of 32 and reduced
  again. A matching two-clock tap pipeline and a coarse subtraction adjustment
  from 1 to 3 clocks preserve sample/timestamp alignment. Timeout observation is
  delayed by the same two clocks, with matching timeout timestamp adjustment,
  to retain the original event-acceptance window. This adds detection
  latency but does not increase legacy FIFO throughput to the width-path rate.
- Pulse output ownership/GPIO selection moves before two preserved output-data
  registers directly driving ODDR. The drive guard and cycle marker match the
  extra 4 ns stage. Byte-wise phase increment uses lookahead carries; D2 compares
  the half-period values directly rather than adding one before comparing.

Default frame minimum is **500 ns (2 MHz)**, reported at offset 0x144. A static
processing budget increases that minimum for a parameterized encoder whose scan
would not fit. The default 64-clock scan plus 32 reserved clocks is below the
125 fast clocks in a 500 ns frame; ring overflow detection remains active. This
is a design limit pending implementation and board validation, not a measured
2 MHz acceptance result. Memory capacity remains 16384 records. The API already
reads the hardware minimum; register/SCPI formats are unchanged, so no API/server
rebuild is required. VERSION becomes **10**, legacy ID **0x5444430a**, PWB ID stays
0x50574201. BNET remains excluded using DISABLE_BNET, with source retained.

This does **not** implement continuous 50 MS/s, arbitrary sub-clock whole-pulse
capture, or streaming. Edge detection still observes sampled tap 0; the existing
HIGH/LOW limitations and frame rejection semantics remain. More parallel/pipelined
encoding and a different acquisition/readout architecture are needed for 50 MHz.

Copy current sources into the project with `scripts/refresh_custom_sources.tcl`,
reset synthesis/implementation runs, and build a new image. This script uses
`import_files` to make and verify project-owned copies rather than direct source
references. Diagnostics/checker selectors include both new encoder hierarchies.
Record routed timing/utilization and bitstream identity before loading.

Recalibrate both edge LUTs for the new implementation. The old v9 missing-code
exceptions (FALL 91..93 and 99..101) do not automatically apply to v10. The Rigol
notebook now expects version 10, starts with no missing-code exceptions, retains
historical v9 outputs, and adds about 1.5/2 MHz points in its rate sweep. Start
from configuration/preflight and enter the new image label and WNS; do not reuse
old kernel captures/candidates for the new image. Compile/simulation and routed
acceptance for this change must be distinguished from historical v9 checks.

### V9 falling-edge and control-path repair (historical)


The direct-AWG v8 run at 997 kHz restored normal frame acceptance, but 5.46%
of complete pulses still had invalid FALL codes; every rejected returned index
was 1 modulo 4. This suggests carry-word/polarity structure, without proving
which physical tap skew causes it. The v8 encoder inverts a sampled falling
wave after it passes through the carry chain; this cannot remove physical
falling-wave propagation skew. V9 instead drives an added independent chain
with `~event_i`, so an external falling edge propagates as a rising wave.

Width hierarchy now contains **i_carry** for the external rising edge and
**i_fall_carry** for the external falling edge. Both have 128 CARRY4 primitives
and 512 tap FFs by default, use the same 250 MHz sampling clock, and have local
registered reset leaves. Falling-edge detection/timestamping uses the new
chain's first tap, with matching raw snapshot pipeline latency. The raw FALL
bank is no longer bit-inverted. Through v11 the majority filter and strict malformed-code
rejection are unchanged; this repair does not lower calibration validity gates.

The additional sampler costs 128 CARRY4 and approximately 1536 data/tap FFs,
plus a few control FFs; the result buffer and LUT sizes remain unchanged.
All three physical chains (legacy, width RISE, width FALL) require separate
legal placements. The managed XDC, collection checker, diagnostics and placement
helper comments include the new hierarchy. No placement coordinates are chosen
here. The refresh helper copies the changed RTL and XDC into the Vivado project.

The -1.143 ns routed build's remaining paths are addressed by:

- Registering 32-bit groups of LUT-written bits, then overall completeness.
  Bitmap write/clear enables are independent of activation validity. Readiness
  asserts two bus clocks after the final table write; activation must observe
  the ready bit first (the existing settling-read API covers this latency).
- Registering `last_frame` with the remaining count, including preload and
  a lookahead update at each closing marker, rather than comparing the count
  in the state/timestamp-enable path.
- Registering timeout expiry one count ahead. `TIMEOUT-2` is computed on the
  bus side, and a separate TIMEOUT=1 flag seeds expiry at each counter restart.
  Timeout/marker priority and the previous terminal cycle are retained.
- Giving unused metadata cycles real frame data with write-enable inactive,
  instead of zeroing the entire word through the wide control decode.

The legacy ID becomes **0x54444309**, and `TDC:WIDTH:VERSION?` returns **9**.
PWB ID, register offsets, raw/status format, read readiness and 16384-record
capacity stay compatible. The current v8 API/server support v9 without another
software rebuild. Recalibrate both LUTs after the new image is implemented;
old rising as well as falling tables are invalid after placement changes.
Separate chain input-route delay contributes a fixed width offset and must be
checked against independent known widths after code-density calibration.

These are source repairs, not a timing-closure or accuracy result. Only static
HDL compilation has been performed; no simulation or Vivado was run. Verify
routed timing/DRC/CDC/utilization before accepting the new capture/calibration.

The v10 default limits acquisition to **2 MHz or slower**
FPGA frame triggers, at **50% drive duty**. Pulse generation itself retains its
existing frequency range. 125 MHz pulse-width capture is a future target.
The 250 MHz sampler has a nominal **4 ns coarse tick**; use HIGH and LOW gaps
of at least **8 ns**, and characterize actual detection limits on the board.
Narrower pulses/gaps can be missed or merged; a small printed ps unit is not
proof of ps resolution. Completed pulse frames are encoded while later frames
are captured; compact results are retained for readout after the burst.

Wire DIO1_P / **E1 pin 5** to the PCB trigger input. Wire its confirmed 3.3 V
single-ended output to DIO2_P / **E1 pin 7**, with E1 ground 25/26. Select
`TDC:INPUT SINGLE`; the LVDS return alternative remains E3 contacts 31/33.
**Do not connect E3 launch contacts 7/9 for this PCB protocol.** The independent
legacy E3 launch is suppressed during width acquisition, and legacy enable
and test modes must be OFF before arming.

The carry path remains running. Trigger boundaries manage cycle IDs and
capture ownership; they do not reset the physical delay line. Separate raw
snapshots and coarse times retain the PCB rising and falling edges, including
a falling edge arriving while the old serial encoder would still be busy.
A burst of N records uses N+1 observed trigger boundaries. Memory freezes
before software receives completion, so delayed/repeated reads are stable.
The default capacity is **16384 records**, with a default requested count of 16.
This matches the ADC buffer's record count, not its sampling rate. At 1 MHz,
16384 pulse periods span **16.384 ms**; at 2 MHz they span **8.192 ms**,
at 5 MHz **3.2768 ms**, and at25 MHz **655.36 microseconds**,
plus initial alignment and final decoding.

Only **four raw frames** are staged at once, with a separate capture controller
and result processor. V17's parallel width encoders use registered binary trees
with12-clock latency and overlapping frame initiation. The bounded-population
validator/status layout remains; the one-tap legacy encoder stays strict.
The40 ns frame limit budgets initiation and result retirement, not total latency.
A stalled/faulting processor raises OVERFLOW and discards the
burst, rather than overwriting an unread frame silently.

Each stored result is **99 bits** at 512 taps: flags, coarse ticks, two 9-bit
indices and a signed 17-bit fine correction. The redundant 32-bit width is
reconstructed as coarse_ticks*4000 + correction on readout. Coarse-only records
store a zero correction; invalid records still return width_ps=0. The correction
is frozen per record, so later LUT edits cannot change a completed measurement.
Cycle ID is derived from the address; the API still reads the same five 32-bit
words and all public fields are preserved. The result buffer is **198 KiB**,
plus a 560-byte raw-frame ring, 2 KiB of LUT data and V16's 2 KiB sparse diagnostic data. The raw ring uses distributed
RAM; results use block RAM. This replaces the v5 scheme whose full raw snapshots
would need about 2.44 MiB at this depth. Actual BRAM packing and the remaining
resources in the merged BNET/scope/ASG design require an external utilization
check. No array is bulk-reset in the capture logic.

### V6 resource failure and V7 storage repair

The user's V6 implementation failed **DRC UTLZ-1: 286 RAMB18-equivalent units
required, 280 available**. The saved synthesis log inferred 57 RAMB36 blocks
for its 16K x 114 result array. The V7 16K x 99 format saves 30 KiB of logical
storage; ordinary 16K x 2 RAMB36 packing predicts about 50 RAMB36 blocks,
roughly seven fewer than before. This is an estimate until the new synthesis
and implementation reports are available. The saved synthesis report's 135
BRAM tiles did not establish fit: the later implementation reported 143 tile
equivalents. Inspect the optimized/implemented resource totals as well.

V7 also registers the RAM write enable, address and data without asynchronous
reset on those port registers, addressing the reported REQP-1839 warnings
from asynchronous state/address drivers. The final pending write commits before
completion becomes visible to the bus. Readout has a RAM-read and constant-scale
pipeline; the existing API's 16 settling reads cover both stages. No Vivado was
run locally; resource fit, DRC and routed timing require an external rebuild.

The first external synthesis reported **Synth 8-3391** for the 524288-bit
`rise_memory_reg` array. The previous conditional assignments to current and
next-frame addresses prevented block-RAM inference. The repaired RTL selects
write enable/address/data outside the memory process and gives each capture
RAM exactly one write statement and one synchronous read. Later designs keep
that access pattern for both the small ring and the larger result memory.
Refresh the project-local `tdc_pulse_width.sv`, `tdc_thermometer_encoder.sv` and
`tdc_registers.sv` copies and reset synthesis before retrying.
Do not use the suggested `dissolveMemorySizeLimit` increase as the repair:
expanding this buffer into individual bits would defeat block-RAM inference.
Local simulation and HDL checks cannot confirm Vivado's inferred resources;
inspect the new synthesis log and hierarchical utilization on the build machine.

### First-board sequence

Rebuild/reload the FPGA; the V16 API plus statically linked SCPI already supports
V17. Check `0x54444311` at `0x40710000` and `0x50574201` at `0x40710100`.
`TDC:WIDTH:VERSION?` reports17; `MINIMUM:PERIOD?` reports40 and
`DIAGNOSTIC:CONFIG?` reports64,256 with the default build.
`TDC:WIDTH:CAPACITY?` must return16384. The v5/PWB v1
API register layout remains compatible; the updated script removes its old
1024-record limit and understands the added overflow status.
Start pulse_gen **before** width ARM, avoiding a network round-trip inside the
stopped-trigger watchdog. ARM sets that watchdog to two configured periods
plus 32 sampler clocks; a trigger stopped mid-burst produces an explicit error.

```text
PULSE:OUTPUT OFF
TDC:ENABLE OFF
TDC:TEST:INTERNAL OFF
TDC:MMCM:ENABLE OFF
TDC:RESET
TDC:INPUT SINGLE
TDC:WIDTH:CALIBRATION:ACTIVATE OFF
PULSE:TIMING 1000,500
PULSE:OUTPUT ON
TDC:WIDTH:ARM 16
TDC:WIDTH:STATUS?
```

Poll STATUS until bit 0 (BUSY) clears; require DONE and no global error. Then:

```text
PULSE:OUTPUT OFF
TDC:WIDTH:COUNT?
TDC:WIDTH:DATA? 0,16
```

DATA replies with semicolon-separated records, each containing:
`cycle_id,flags,coarse_ticks,rise_raw,fall_raw,width_ps`.
Read 1..128 records per query; indexes are zero-based, cycle IDs start at one.
Use `TDC:WIDTH:ABORT` to discard a running burst, then poll BUSY clear before
reconfiguration. `TDC:WIDTH:CLEAR` invalidates the completed buffer; it does
not turn off pulse_gen. Let an already-triggered PCB pulse finish before rearm.

The app's `scpi-tests/tdc_pulse_width_test.py BOARD_IP --count 16` implements
this sequence, prints all flags and can save CSV with `--csv result.csv`.
It finishes with pulse output OFF and an abort command, and reports invalid
cycles rather than treating zero as a successful width measurement.

After the short wiring test, capture the full buffer from the app workspace:

```text
python scpi-tests/tdc_pulse_width_test.py BOARD_IP --count 16384 --csv tdc_width_16384.csv --quiet
```

The script reads 128 records per query (128 queries for the full burst).
`--quiet` suppresses per-pulse printing while preserving every CSV row and
the validity/error checks. This remains finite capture followed by readout;
it does not implement continuous PC streaming.

### Width register page

Offsets below are relative to TDC base `0x40710000` (not the pulse-generator base).

| Offset | Access | Meaning |
|---:|---|---|
| 0x100 | R | PWB ID/version: `0x50574201` |
| 0x104 | W | Exactly one command: 1 ARM, 2 ABORT, 4 CLEAR |
| 0x108 | R | Status flags below; BUSY covers command transfer, capture and processing |
| 0x10c | R/W | Requested record count 1..CAPACITY; idle only |
| 0x110 | R | Record capacity, default 16384 |
| 0x114 | R | Completed result count; reads zero while busy |
| 0x118 | R/W | Record index, idle and below completed count |
| 0x11c | R | Selected record word 0: cycle ID |
| 0x120 | R | Word 1: record flags |
| 0x124 | R | Word 2: coarse width ticks |
| 0x128 | R | Word 3: rise raw index in bits 15:0; fall raw index in bits 31:16 |
| 0x12c | R | Coarse tick, nominal 4000 ps |
| 0x130 | R/W | Stopped-trigger timeout in 4 ns clocks; idle only; ARM API derives it from pulse timing |
| 0x134 | R | Word 4: width in ps; valid only with record VALID flag |
| 0x138 | R/W | Width LUT address: rise 0..511, fall 512..1023 |
| 0x13c | R/W | Width LUT entry, 0..65535 ps; idle only |
| 0x140 | R/W | Write: 1 invalidate tables, 2 activate, 4 disable. Read: bit 0 enabled, bit 2 both tables fully written |
| 0x144 | R | Minimum trigger period: V17 default40 ns; V16 default200 ns; V14/V15 default500 ns; read hardware |
| 0x148 | R | v8+: bit 0 READ_READY; bank/readout arithmetic pipeline settled after selecting an index; zero during BUSY |
| 0x158 | R/W | v14: acquisition frame offset in ns, idle only; multiple of4,0..262140,strictly less than launch period; FPGA-reset0 |
| 0x15c | R | v14 frame-offset capability:0x46524d01 (FRM v1) |
| 0x160 | R | V16 sparse-edge capability:0x44424701 (DBG v1) |
| 0x164 | R | V16 diagnostic record stride:64 |
| 0x168 | R | V16 selected record RISE tick; idle, completed index divisible by64, same READ_READY protocol |
| 0x16c | R | V16 selected record FALL tick; same restrictions; 32-bit wrap |

Status bits: 0 BUSY, 1 CAPTURING (including wait for first trigger), 2 PROCESSING,
3 DONE, 4 TRIGGER_TIMEOUT, 5 RATE_ERROR, 6 ABORTED, 7 OVERFLOW (raw-frame ring).
CAPTURING and PROCESSING can both be set. On abort, unsafe rate or overflow,
partial results are discarded. A stopped trigger can preserve partial frame records
marked invalid along with the global timeout. A new ARM hides old completion
flags while busy; input changes invalidate old results and width calibration.

Record flags:

| Bit | Meaning |
|---:|---|
| 0 | VALID: one observed rising/falling pair, no frame error |
| 1 / 2 | NO_RISE / NO_FALL |
| 3 | Input HIGH at cycle start without a new observed rise |
| 4 | Extra edge(s) in the frame |
| 5 | Trigger timeout interrupted the frame |
| 7 | FINE_INVALID: at least one carry snapshot did not encode as a valid thermometer |
| 8 | COARSE_ONLY: width uses 4 ns ticks; no fine correction applied |
| 9 | CALIBRATED: uploaded rise/fall LUT correction applied |
| 10 | Falling edge exactly at observed trigger boundary; frame marked invalid |
| 11 | SATURATED: missing falling edge while input remains HIGH |
| 12 | OUT_OF_RANGE: coarse ps value exceeds the 32-bit width field; invalid |
| 23:16 / 31:24 | Rise / fall encoder diagnostic status bytes, using legacy encoder flag definitions |

VALID may accompany COARSE_ONLY and FINE_INVALID: the coarse pair is usable
but the raw fine interpolation is not. Invalid frames have width_ps=0 and
must be distinguished by flags. The maximum representable width is about
4.295 ms; larger coarse results are flagged rather than wrapping.

### Width calibration and implementation checks

Default correction is OFF. Do not apply the old 125 MHz TDC LUT to this
separate 250 MHz carry path. After characterizing the placed width path,
upload **both** measured 512-entry tables using:

```text
TDC:WIDTH:CALIBRATION:LUT:WRITE RISE,0,<values...>
TDC:WIDTH:CALIBRATION:LUT:WRITE FALL,0,<values...>
TDC:WIDTH:CALIBRATION:ACTIVATE ON
TDC:WIDTH:CALIBRATION:ACTIVATE?
```

Uploads can be split into address ranges. Activation requires every entry of
both tables to have been written. Editing a table disables correction; input
changes invalidate table readiness. Width = coarse_ticks * 4000 + rise_LUT -
fall_LUT. Invalid fine codes fall back to coarse timing with flags. No automatic
code-density calibration or certified fine accuracy is supplied by this release.

Refresh project copies with the updated helper, which now includes
`tdc_pulse_width.sv`. Keep all tbn replacement models out of Vivado filesets.
The new carry hierarchy is `i_tdc/i_width/i_carry`; the legacy path remains
`i_tdc/i_carry`. Placement helpers accept that hierarchy as an optional final
argument. Choose separate legal locations; no coordinates were selected here.
The TDC XDC includes intentional tap/synchronizer exceptions and bounded
configuration/completion transfers. Ordinary capture, encoder, RAM, reset
release and arithmetic paths remain timed. Source the collection checker in
the new synthesized design, then inspect timing, CDC, DRC and resource use.
The checker now also requires dedicated RAMB primitives under the width block;
its presence check does not replace reviewing total utilization and packing.

Local ideal-delay/controller tests cover both edges, full burst capacity,
coarse and synthetic LUT results, missing/extra edges, saturation, rate rejection,
watchdog, abort/rearm, trigger-boundary RAM writes, forced staging overflow,
signed corrections up to +/-65535 ps, frozen results after LUT edits, and
width-first CDC readout after each address change.
The standalone width testbench also supports `FULL_SIZE=1` for the production
512-tap / 16384-record dimensions, checking every result and capture/encoding overlap.
The earlier V6 full 1 MHz regression passed. For V7, the short correction,
integrated and fault regressions passed; the full-buffer run was stopped at
the user's request so they can verify in Vivado. No V7 full-run PASS is claimed.
Before the October 16 timing changes below, the grouped encoder test compared
both modes to an independent reference, including exhaustive 16-tap patterns
and 17/512-tap cases; those earlier runs passed.
These tests do not establish Vivado RAM inference or
physical carry delays, board detection limits, fine accuracy or routed timing.

### October 16 routed-timing repair (implementation pending)

The diagnostic implementation reported setup failures in capture RAM controls
and data, the encoder, and both result-RAM ports. The HDL now:

- Pipelines raw taps, write enables, addresses and frame metadata together by
  two clocks. An extra fetch state waits for the delayed writes and registered
  RAM reads before encoding a closed frame. Edge timestamps are unchanged.
- Separates encoder chunk filtering/prefix analysis, running accumulation,
  and final status/index output. Chunks still enter every clock; each edge
  takes two additional clocks to drain the pipeline. Bubble/status rules are
  unchanged, including rejection of multiple transitions.
- Replaces capture-path full-counter subtraction with a small staging-occupancy
  counter and a bounded remaining-frame countdown. Precomputes timeout minus
  one in the bus domain; the bounded configuration CDC constraint includes
  this new `timeout_last_cfg` register.
- Splits result storage into banks of at most 1024 records, with local write
  address/data/enable registers and local registered read addresses. At default
  dimensions there are 16 banks of 99-bit records. The logical capacity and
  register map remain unchanged. Actual BRAM packing must be checked in Vivado.
- Pipelines bank selection and the exact `coarse_ticks * 4000 + fine_delta`
  readback calculation. Allow **seven bus clocks after changing READ_INDEX**
  before sampling width data; raw record fields settle after four clocks.
  The existing API already performs sixteen settling reads of READ_INDEX
  before fetching any record fields, so it needs no rebuild for this change.
  Direct-register testbenches or other bus clients must also allow this latency.
- Waits for both result-write pipeline stages to commit before publishing DONE.

No simulation or Vivado runs were performed for this patch. Historical test
passes above do not validate the new pipelines. Refresh project-local copies
with `scripts/refresh_custom_sources.tcl`, reset stale synthesis/implementation
runs, then rebuild and source `scripts/diagnose_tdc_width.tcl` on the routed
design. The diagnostic helper now follows the banked RAM and capture pipelines
and emits utilization and bus-skew reports as well. Direct tap-to-RAM reports
can have no paths after pipelining; inspect both sides of the capture stages
and the overall width-internal report instead. The unrelated butterfly/SDF
timing violations have not been changed by this TDC repair.

### October 19 follow-up: distortion investigation and interface v8

Only the October 16 routed reports are available; neither set of timing edits
has a new implementation result. Saved sine data has a large repeatable second
harmonic and contradictory flags every eighth record. The width path has no
5 us/50%-duty clamp or sine/voltage mapping: coarse width is an edge timestamp
difference. With fine calibration OFF the encoder index cannot alter that
width. Ordinary 4 ns quantization alone does not explain the observed 15 ns
periodic fit residual. Bad capture/readback timing and the PCB transfer remain
separate hypotheses; code review cannot identify the physical cause uniquely.

The v8 follow-up makes these additional changes:

- Byte-wise timestamp and watchdog counters with registered, one-tick-ahead
  carries replace 32-bit increment feedback. All watchdog carries reset when
  a trigger restarts the interval. A stable terminal count uses equality.
- Capture stores rise/fall timestamps in the four-slot metadata ring. The
  processor computes the unsigned modulo-2^32 difference in two 16-bit steps,
  removing the subtraction from the falling-edge capture/write path.
- LUT fetch, signed fine subtraction, constant coarse scaling, and final
  correction are separate processing stages. The internal coarse ps field
  needs 44 bits and signed corrected width needs 45, rather than 64.
- A balanced chunk prefix tree replaces the serial encoder loop. A redundant
  512-bit encoder-input register and reset of the overwritten shift bank are
  removed. Majority filtering and invalid-code rejection remain unchanged.
- READ_READY at 0x148 becomes true after seven bus clocks with a stable index
  and idle buffer. The updated API polls it on v8+; older images retain the
  sixteen settling reads. The existing register layout/PWB v1 ID is preserved.
- Normal `rp_TdcWidthRead` / `TDC:WIDTH:DATA?` now reject contradictory flags,
  bad cycle IDs/indices and impossible width/correction combinations with an
  API error. `rp_TdcWidthReadRaw` / `TDC:WIDTH:DATA:RAW? start,count` retains the
  six original fields for diagnosis without consistency rejection. It never
  repairs or drops records. Raw results must not be accepted as calibration.
  The notebook helper also audits old-server captures before accepting a fit.

The shared SDF butterfly's worst reported DSP-to-RAM path is now split into
registered product, sum, rounding and saturation stages. Valid, type, address,
saved feedback and last-input markers follow all four extra clocks. Delays
1/2/4 use a four-entry forwarding bank at the delayed calculation stage;
longer delays retain synchronous RAM reads. The new arithmetic pipeline resets
only its valid registers; small x/y delay RAM storage is written before use and no longer bulk
resets. This changes BNET latency by four clocks per active SDF stage; it
requires fresh BNET numerical/ordering and hardware acceptance as well as TDC
checks. The source refresh now imports this SDF source into a project copy.

No tests or Vivado runs were performed for this follow-up. The existing test
drivers' expected ID and readout settling delay were updated for compatibility;
historical PASS logs apply to earlier code. Do not accept new fine LUTs until
timing, record consistency and independent pulse-width checks are satisfactory.

## Legacy E3 launch and LVDS return allocation

| Function | Top-level port | E3 signal | E3 connector contacts P/N | Zynq package pins |
|---|---|---|---|---|
| Launch output to PCB | `exp_e3p_o[0]`, `exp_e3n_o[0]` | DIO17 P/N | **7 / 9** | T5/U5 |
| Delayed return from PCB | `exp_e3p_i[0]`, `exp_e3n_i[0]` | DIO18 P/N | **31 / 33** | V11/V10 |

Use E3 ground contact 16, 22 or 26 for the common reference. These connector
contact numbers are distinct from FPGA package ball names. Pinout reference:
[STEMlab 125-14 PRO Z7020 Gen 2 E3 table](https://redpitaya.readthedocs.io/en/latest/developerGuide/hardware/GEN2/125-14_Gen2_Z7020_Pro/top.html#e3-connector-qspi-emmc-power-control).
Feed an LVDS-compatible differential signal into the return pair; do not
connect a 3.3 V GPIO signal directly to this 2.5 V bank.

Both pairs use `LVDS_25` in `red_pitaya_G2.xdc`. The user confirmed an LVDS
return with no external termination, so the TDC instantiation and defaults now
enable `DIFF_TERM` for the FPGA input's internal 100-ohm differential termination.
If external receiver termination is added later, disable the internal one.

E3 indices 3:1 remain attached to `red_pitaya_daisy` as one clock and two data
lanes. Index 0 no longer belongs to that auxiliary serializer.

For initial external single-shot operation, the TDC generates its own launch
edge and measures the PCB's corresponding delayed return. An unrelated free
running input is not a controlled launch-to-return delay test. Configure source
selection with the TDC disabled. Use a new implementation and fresh timing
reports after changes; the internal MMCM test does not validate the E3 link.

## Selectable single-ended return (interface v4)

`TDC:INPUT SINGLE` selects **DIO2_P, E1 contact 7, FPGA J18,
`exp_p_io[2]`**, instead of the LVDS return. The user confirmed the PCB output
is a **3.3 V digital signal**. Connect PCB ground to E1 contact 25 or 26.
The existing board `sdc/red_pitaya.xdc` already assigns J18 / LVCMOS33;
no additional pin XDC is needed. This pin is permanently input-only in the
custom top, even if housekeeping GPIO direction registers request output.
Do not attach a 100-ohm shunt terminator to this single-ended input.

`TDC:INPUT LVDS` restores the E3 return pair. `TDC:INPUT?` reports `LVDS` or
`SINGLE`. MMCM/internal test selection still overrides either external input,
so turn both test sources OFF for PCB acquisition. The E3 launch pair and the
launch-to-return measurement procedure are the same for both external inputs.
Only one input is measured at a time, on a rising edge; the selected signal
must return LOW before the next acquisition.

Set ENABLE OFF and wait for STATUS bit 0 to clear, or use TDC:RESET to abort
an unfinished acquisition, before changing input. A changed selection resets
controller/results/FIFO/event counters, clears the histogram, and disables
LUT correction. It preserves other control settings. Wait for histogram clear
completion before collecting calibration data; reload a LUT and characterize
the offset for the selected input path before calibrated measurements.
Rewriting the same selection while disabled/idle has no reset side effects.
Soft reset preserves the external selection. FPGA reset selects SINGLE in V18;
V17 and earlier reset to LVDS. Explicit LVDS selection remains available.

Rebuild and load the FPGA image and rebuild/redeploy both the API and statically
linked SCPI server. The new API rejects input selection on pre-v4 FPGA images.

```text
TDC:ENABLE OFF
TDC:TEST:INTERNAL OFF
TDC:MMCM:ENABLE OFF
TDC:RESET
TDC:INPUT SINGLE
TDC:INPUT?
TDC:MODE SINGLE
TDC:ENABLE ON
TDC:MEASURE?
TDC:ENABLE OFF
```

## Address allocation

The PS UIO map already exposes slot 7 as `0x40700000..0x407fffff`.

| Physical range | Slot-7 offset | Owner |
|---|---:|---|
| `0x40700000..0x4070ffff` | `0x00000` | Existing BNET registers |
| `0x40710000..0x4071ffff` | `0x10000` | TDC registers |
| `0x40720000..0x4072ffff` | `0x20000` | GPIO pulse-generator registers |
| remaining slot-7 ranges | other | Acknowledged bus error |

The Red Pitaya C API uses relative UIO offsets. BNET remains at `0x00700000`;
the TDC maps slot 7 and adds byte offset `0x10000`. No device-tree edit is
needed because the existing slot is one MiB.

## Register map

All registers are 32-bit and require word-aligned accesses. Pulse fields take
effect once even though the system-bus request remains asserted until `ack`.
Both register pages validate and capture a response only on the first request
clock. ACK/ERR and read data remain stable while the request is held; read data
is also retained after release for the system-bus CDC return path. In particular,
an accepted width ARM must not turn into a bus error when it sets BUSY on the
following clock. Live status is refreshed by the next transaction, not by idle
clocks or changes to an inactive bus address.

The legacy E3 launch countdown runs to completion before another acquisition
can launch. This prevents short return/encoding latency from reloading a long
pulse's countdown in continuous mode. A queued single trigger still waits for
the current launch and return path to become LOW. Disabling ENABLE prevents
new launches; an already started launch retains its configured width. SOFT_RESET
can terminate it immediately. Continuous launch rate also depends on return,
encoding and re-arm time; LAUNCH_PERIOD is not a guaranteed waveform period.

| Offset | Register | Access | Reset / description |
|---:|---|---|---|
| `0x00` | `ID_VERSION` | R | `0x54444311` (`TDC`, V17: 25 MHz frame initiation, registered encoder trees) |
| `0x04` | `CONTROL` | R/W | Persistent and pulse control fields below |
| `0x08` | `STATUS` | R | Live state and FIFO level fields below |
| `0x0c` | `LAUNCH_PERIOD` | R/W | 125000 clocks (1 ms at 125 MHz); zero clamps to one |
| `0x10` | `LAUNCH_WIDTH` | R/W | 2 clocks (16 ns); zero clamps to one |
| `0x14` | `TIMEOUT_CYCLES` | R/W | 125000 clocks; zero clamps to one |
| `0x18` | `NUM_TAPS` | R | 512 in the initial build |
| `0x1c` | `CLOCK_PERIOD_PS` | R/W | 8000 ps; zero clamps to one |
| `0x20` | `LAST_COARSE` | R | Coarse cycles belonging to the last result |
| `0x24` | `LAST_FINE_RAW` | R | Corrected thermometer transition index |
| `0x28` | `LAST_FINE_PS` | R | LUT bin-center propagation time, or diagnostic average-bin time |
| `0x2c` | `LAST_TOTAL_LO` | R | Bits 31:0 of total time in ps |
| `0x30` | `LAST_TOTAL_HI` | R | Bits 45:32 of total time in bits 13:0 |
| `0x34` | `LAST_STATUS_SEQ` | R | Sequence in bits 31:16, result status in bits 7:0 |
| `0x38` | `FIFO_LEVEL` | R | Number of queued 128-bit records |
| `0x3c` | `FIFO_SNAPSHOT0` | R | Snapshot bits 31:0 |
| `0x40` | `FIFO_SNAPSHOT1` | R | Snapshot bits 63:32 |
| `0x44` | `FIFO_SNAPSHOT2` | R | Snapshot bits 95:64 |
| `0x48` | `FIFO_SNAPSHOT3` | R | Snapshot bits 127:96 |
| `0x4c` | `FIFO_CONTROL` | W | bit 0 pop-to-snapshot; bit 1 clear |
| `0x50` | `CAL_ADDR` | R/W | Inactive LUT / histogram address, 0..511 |
| `0x54` | `CAL_DATA` | R/W | Inactive LUT 16-bit bin-center value in ps |
| `0x58` | `CAL_CONTROL` | R/W | Calibration command/status fields below |
| `0x5c` | `HIST_ADDR` | R/W | Alias of `CAL_ADDR` |
| `0x60` | `HIST_DATA` | R | Selected 32-bit histogram bin |
| `0x64` | `EVENT_COUNT` | R | Valid results since core reset |
| `0x68` | `ERROR_COUNT` | R | Invalid and timeout results since core reset |
| `0x6c` | `RAW_WORD_ADDR` | R/W | Raw tap word selector, 0..15 |
| `0x70` | `RAW_WORD_DATA` | R | Selected word of the last captured 512-bit vector |
| `0x74` | `IRQ_MASK` | R/W | Stored mask; interrupt output is not connected in v1 |
| `0x78` | `IRQ_STATUS` | R/W1C | bit 0 FIFO overflow; bit 1 FIFO nonempty occurred |
| `0x7c` | `CAL_TARGET` | R/W | Valid-event target; zero means no automatic completion |
| `0x80` | `MMCM_CONTROL` | R/W | Dedicated MMCM phase-sweep command fields below |
| `0x84` | `MMCM_STATUS` | R | bit 0 `LOCKED`; bit 1 `PS_BUSY`; bit 2 `PS_TIMEOUT` |
| `0x88` | `MMCM_COARSE_DELAY` | R/W | Extra whole `clk_i` cycles inserted before the commanded edge fires; 0 by default |
| `0x8c` | `MMCM_PHASE_COUNT` | R | Signed accumulated dynamic phase-shift step count since the last clear/reset |
| `0x90` | `INPUT_SELECT` | R/W | 0 = LVDS (reset); 1 = SINGLE (E1 DIO2_P). Writes require ENABLE=0, BUSY=0; other values are rejected. Persists through soft reset. |

Unsupported or unaligned accesses are acknowledged with `err=1`.

### CONTROL bits

| Bit | Name | Type | Meaning |
|---:|---|---|---|
| 0 | `ENABLE` | persistent | Arm the selected operating mode |
| 1 | `SINGLE_TRIGGER` | pulse | Start one isolated launch when idle |
| 2 | `CONTINUOUS` | persistent | Launch periodically |
| 3 | `SOFT_RESET` | pulse | Reset controller, counters and FIFO; persistent control clears |
| 4 | `FIFO_CLEAR` | pulse | Clear FIFO only |
| 5 | `RAW_CAPTURE_ENABLE` | persistent | Reserved policy bit; last raw vector is always retained in v1 |
| 6 | `HISTOGRAM_ENABLE` | persistent | Increment the valid-index histogram |
| 7 | `USE_CALIBRATION_LUT` | persistent | Use active LUT instead of average-bin diagnostic conversion |
| 9 | `CALIBRATION_MODE` | persistent | Arm for asynchronous external return events; do not launch |
| 10 | `INTERNAL_TEST` | persistent | Select divided PS fabric-clock stimulus instead of the E3 return; suppress E3 launches |
| 11 | `MMCM_SWEEP_ENABLE` | persistent | Select the dedicated MMCM phase-swept edge instead of the E3 return or `INTERNAL_TEST`; suppress E3 launches |

Single mode requires `ENABLE=1` before issuing `SINGLE_TRIGGER`. If both bit 10
and bit 11 are set, bit 11 (MMCM sweep) takes priority. `SOFT_RESET` preserves
both bit 10 and bit 11 across the reset, exactly like the existing internal
self-test selection.

### STATUS bits

| Bits | Name | Meaning |
|---:|---|---|
| 0 | `BUSY` | Controller is outside IDLE |
| 1 | `FIFO_NONEMPTY` | At least one result is queued |
| 2 | `FIFO_FULL` | Result FIFO is full |
| 3 | `LAST_TIMEOUT` | Last result has the TIMEOUT flag |
| 4 | `LAST_INVALID` | Last result does not have VALID set |
| 5 | `ACTIVE_LUT_BANK` | Active LUT bank number |
| 6 | `HIST_CLEAR_BUSY` | Iterative 512-bin clear is running |
| 7 | `FIFO_OVERFLOW` | Overflow pulse from the FIFO |
| 16:8 | `FIFO_LEVEL` | Nine-bit queue depth |
| 17 | `CALIBRATION_COMPLETE` | Valid-event target has been reached |
| 18 | `INTERNAL_TEST` | Internal asynchronous stimulus is selected |
| 19 | `MMCM_SWEEP_ENABLE` | Dedicated MMCM phase-sweep source is selected |
| 20 | `MMCM_LOCKED` | Dedicated MMCM has achieved lock |
| 21 | `MMCM_PS_BUSY` | A dynamic phase-shift step is in progress |

## Dedicated MMCM phase-sweep self-test

`tdc_mmcm_stimulus.sv` instantiates a dedicated `MMCME2_ADV` (belonging only to
this self-test, never the shared `red_pitaya_pll`) fed from the same `clk_i`
(`adc_clk`) reference used elsewhere in the TDC. `CLKFBOUT_MULT_F=8`,
`DIVCLK_DIVIDE=1` gives a 1000 MHz VCO from the nominal 125 MHz input;
`CLKOUT0_DIVIDE_F=8` regenerates 125 MHz with `CLKOUT0_USE_FINE_PS="TRUE"`, so
each dynamic phase-shift step is nominally `1 / (56 * 1000 MHz) ~= 17.86 ps`.
A software-issued fire request is translated into exactly one rising edge on
that phase-shifted clock and fed to the same carry-chain measurement node
used by the E3 return and the divided-`fclk[0]` internal source. Select it
with `CONTROL.MMCM_SWEEP_ENABLE` (bit 11); it arms and waits for its own
commanded edge exactly like `INTERNAL_TEST` and never drives the E3 launch.

### MMCM_CONTROL bits

| Bit | Write meaning |
|---:|---|
| 0 | `PS_REQUEST` (pulse): request one dynamic phase-shift step |
| 1 | `PS_INCDEC` (persistent): 1 = increase delay, 0 = decrease delay for the next `PS_REQUEST` |
| 2 | `PHASE_COUNT_CLEAR` (pulse): zero `MMCM_PHASE_COUNT` |
| 3 | `MMCM_RESET` (pulse): reinitialize the MMCM (`RST`, held internally for several `clk_i` cycles) |
| 4 | `TIMEOUT_CLEAR` (pulse): clear the sticky `PS_TIMEOUT` status flag |

A read of `MMCM_CONTROL` returns the persistent `PS_INCDEC` bit only.

### MMCM_STATUS bits

| Bit | Meaning |
|---:|---|
| 0 | `LOCKED` |
| 1 | `PS_BUSY`: a requested phase step has not yet completed |
| 2 | `PS_TIMEOUT`: the last phase step did not receive `PSDONE` within the internal watchdog and was abandoned; sticky until `TIMEOUT_CLEAR` |

### Sweep procedure

The FPGA does not automate a sweep; software issues each step:

1. Confirm `STATUS.MMCM_LOCKED` (or `MMCM_STATUS` bit 0).
2. Optionally set `MMCM_COARSE_DELAY` to walk in whole `clk_i` cycles as well.
3. Write `MMCM_CONTROL` with `PS_INCDEC` and `PS_REQUEST` set; poll `MMCM_STATUS.PS_BUSY` until it clears; check `PS_TIMEOUT`.
4. Enable `MMCM_SWEEP_ENABLE`, trigger a single-shot measurement, and read the result exactly like any other source.
5. Repeat from step 3 for each phase position, tracking the commanded position from `MMCM_PHASE_COUNT` and `MMCM_COARSE_DELAY`.

This produces a commanded nominal coarse+fine phase for boundary,
monotonicity and repeatability testing. It does not calibrate absolute
picoseconds -- the phase-step size is nominal and the clock network adds its
own fixed skew and jitter -- and it does not exercise the E3 electrical path.
Cross-check against an external calibrated delay generator before trusting
absolute timing derived from this source.

## Internal hardware self-test

`tdc_internal_stimulus.sv` divides the PS `fclk[0]` clock by 2048 and supplies
its square-wave output to the same carry-chain input node selected by the E3
`IBUFDS`. At the nominal 125 MHz PS clock this gives approximately:

```text
rising-event rate = 125 MHz / 2048 = 61.0 kHz
high time         = 8.192 us
low time          = 8.192 us
```

The high/low times exceed the roughly 4.1 us required by the initial 512-cycle
iterative encoder. The source counter is held at zero while internal test is
disabled. Its enable is synchronized into the PS-clock domain, but the stimulus
edge deliberately remains asynchronous to `adc_clk` and the carry sampler.

Enable it with the C API or SCPI:

```text
TDC:TEST:INTernal ON
TDC:TEST:INTernal?
```

For a single internal result:

```text
TDC:RESet
TDC:MODE SINGLE
TDC:ENABle ON
TDC:MEASure?
```

The internal-test selection is preserved by `TDC:RESet`, while enable/mode and
the measurement core are reset. In single mode, the trigger arms for the next
internal rising edge. `total_time_ps` then includes the arbitrary wait from
arming to that edge, so use status, raw index and fine index—not total delay—as
the self-test acceptance values.

For code-density collection:

```text
TDC:TEST:INTernal ON
TDC:CALibration:STARt 100000
TDC:CALibration:STATus?
TDC:CALibration:HISTogram? 0,64
```

The PS clock and ADC sampling clock originate from different clock paths and
are expected to walk through relative phase. Confirm this empirically: the
histogram must populate many bins. If it remains concentrated in a small number
of bins, the clocks are effectively coherent in that build and the internal
source is not suitable for code-density calibration.

Internal self-test validates the placed carry chain, encoder, histogram,
registers and software path. It does not validate E3 pin polarity, LVDS levels,
termination, cable/PCB delay, comparator jitter, or the analogue conversion.
Disable measurement before switching back to the external source:

```text
TDC:ENABle OFF
TDC:TEST:INTernal OFF
```

### CAL_CONTROL bits

Write commands and read status deliberately share bit 3.

| Bit | Write meaning | Read meaning |
|---:|---|---|
| 0 | Write `CAL_DATA` to inactive bank | zero |
| 1 | Atomically swap LUT banks if ready | active bank number |
| 2 | Start iterative histogram clear | histogram-clear busy |
| 3 | Invalidate inactive-bank write coverage | every inactive-bank entry has been written |

Activation is ignored until all 512 entries of the inactive bank have been
written since its last invalidation. The C API returns an error on an attempted
partial activation. Monotonicity is enforced by the host LUT computation and
must also be checked when importing externally generated data.

## Result status and packing

Per-result status flags:

| Bit | Flag |
|---:|---|
| 0 | `VALID` |
| 1 | `NO_TRANSITION` |
| 2 | `MULTIPLE_TRANSITIONS` |
| 3 | `ALL_ZERO` |
| 4 | `ALL_ONE` |
| 5 | `BUBBLE_CORRECTED` |
| 6 | `TIMEOUT` |
| 7 | `FIFO_OVERFLOW` (last-result diagnostic; a full FIFO cannot store the overflowing record) |

FIFO record layout:

| Record bits | Field |
|---:|---|
| 15:0 | sequence ID |
| 23:16 | result status |
| 55:24 | coarse cycles |
| 65:56 | raw fine index |
| 81:66 | fine propagation time in ps |
| 127:82 | total launch-to-return time in ps |

`FIFO_CONTROL.POP` removes exactly one head entry and copies it into the four
snapshot registers. The API serializes pop/read operations and waits for the
system-bus clock-domain crossing before unpacking the snapshot.

## Timing convention

The October 19 routed build still failed timing (WNS -4.119 ns). The subsequent
source repair retains interface v8 and the register/record layouts. Legacy
coarse/fine multiplication and total subtraction now take six additional
controller clocks; acquisition must continue to poll completion. Width fine
LUTs use dual-clock block RAM with registered read ports. Software LUT reads
retain their existing settling-read procedure. Capture/processor functional
resets are synchronous, and the encoder input selection is registered again.
These changes require a new routed implementation before timing acceptance.

The project refresh helper now defaults to `DISABLE_BNET`, retaining TDC and
pulse generation while excluding BNET engines, DDR readers and capture RAM.
The old BNET address region acknowledges accesses with zero-filled reads for
capability probing; it contains no BNET register bank. Set
`custom_enable_bnet 1` before sourcing the refresh helper to restore BNET.

The tap FDRE bank captures the thermometer vector at sampling edge `S`. The
controller observes that bank on `S+1`, so the implementation subtracts that
one observation cycle from its counter value. The reported time is:

```text
coarse_cycles = (counter observed by controller - launch_counter - 1)
total_ps      = coarse_cycles * clock_period_ps - fine_propagation_ps
```

The subtraction convention still requires hardware tests immediately before
and after a sampling-clock boundary. RTL cannot model routed CARRY4 delays.

## Electrical and operating requirements

- Never apply the analogue control signal directly to E3. The PCB must return a
  standards-compatible LVDS digital event.
- Route matched approximately 100-ohm differential pairs and provide a common
  ground between Red Pitaya and the PCB.
- Provide exactly one receiver termination.
- Keep the returned level high for at least 16-24 ns initially. A narrow pulse
  can put both rising and falling edges in the carry line.
- Calibration mode needs an asynchronous or deliberately phase-swept source.
  A fixed synchronous launch/loopback cannot populate all bins.
- A calibration LUT belongs to the exact implemented placement, bitstream,
  supply and thermal condition.
