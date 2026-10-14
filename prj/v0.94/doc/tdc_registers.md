# CARRY4 TDC integration and register map

This block is instantiated by `red_pitaya_top_LED7_mod.sv` for `Z20_G2` builds.
It coexists with BNET and the GPIO pulse generator in system-bus slot 7.
Current workspace setup, validation and next actions are in the
[master handover](../../../../../RedPitaya_app/HANDOVER.md).

## Physical E3 allocation

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
Soft reset preserves the external selection; FPGA reset restores LVDS.

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

| Offset | Register | Access | Reset / description |
|---:|---|---|---|
| `0x00` | `ID_VERSION` | R | `0x54444304` (`TDC`, v4: selectable external LVDS/single-ended input) |
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
