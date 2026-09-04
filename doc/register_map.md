# cdriscv-32s-20 register map

> [!NOTE]
> **This document describes cdriscv-32s-20.** It began as variant 1's and
> has been revised for this variant — the port list, the clock domains,
> the register map and the assumptions of use are this design's. The evidence
> behind it is this variant's own — O1–O7 and O9 are met on this
> repository's runs, O8 (gate level) is open — and any measured figure
> still quoted from variant 1 is labelled as such where it appears. See
> [variant_status.md](variant_status.md) for what holds here.

> **Status.** The peripheral registers are exercised by simulation —
> `make regwalk` walks the map, and `make periph ams rdback safety` drive
> the individual blocks — so the addresses and access types below are
> checked rather than merely written down. The CSR section is checked
> harder still: `make block-csr-equiv` runs this CSR file in lockstep
> against variant 1's for 400 018 cycles. What is *not* established is
> everything above the register level; see
> [variant_status.md](variant_status.md).

## 1. Address map

| Range | Size | Contents |
|-------|------|----------|
| `0x0000_0000` | `ItcmWords * 4` | I-TCM (instruction fetch and data) |
| `0x0200_0000` | 64 KiB | CLINT — standard RISC-V map, data accesses only, **word accesses only** (a sub-word access returns a bus error rather than being widened; a byte write into a 64-bit counter has no defined meaning) |
| `0x1000_0000` | `DtcmWords * 4` | D-TCM (data) |
| `0x2000_0000` | 4 KiB | peripherals, sixteen 256-byte slots |
| everything else | | unmapped, returns a bus error |

Peripheral slots (`0x2000_0000 + slot * 0x100`):

| Slot | Base | Block |
|------|------|-------|
| 0 | `0x2000_0000` | safety controller |
| 1 | `0x2000_0100` | windowed watchdog |
| 2 | `0x2000_0200` | machine timer |
| 3 | `0x2000_0300` | clock monitor |
| 4 | `0x2000_0400` | AMS interface |
| 5 | `0x2000_0500` | memory BIST (I-TCM at `+0x00`, D-TCM at `+0x40`) |
| 6 | `0x2000_0600` | interrupt controller |
| 7..14 | | unused, returns a slave error |
| 15 | `0x2000_0f00` | exported to the SoC over the expansion APB port |

## 2. Machine CSRs

Standard: `mstatus`, `misa`, `mie`, `mtvec`, `mscratch`, `mepc`,
`mcause`, `mtval`, `mip`, `mcycle(h)`, `minstret(h)`, `mvendorid`,
`marchid`, `mimpid`, `mhartid`, and the read-only shadows `cycle(h)`
and `instret(h)`.

Custom:

| CSR | Address | Access | Description |
|-----|---------|--------|-------------|
| `msafestat` | `0x7c0` | RW1C | sticky core-local fault status: [0] register file parity, [1] illegal instruction trap, [2] bus error trap, [3] lockstep alert |
| `msafectrl` | `0x7c1` | RW | [0] fault output enable, [1] software fault trigger (self clearing) |

`mtvec` supports both direct and vectored mode (bit 0). Interrupts are
taken at instruction boundaries only, and only while an instruction is
available in the execute stage.

## 3. Safety controller (slot 0)

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `STATUS` | RW1C | sticky fault status, one bit per source |
| `0x04` | `ENABLE` | RW | per source: contribute to the status |
| `0x08` | `REACT_IRQ` | RW | per source: raise the safety interrupt |
| `0x0c` | `REACT_RST` | RW | per source: request a reset |
| `0x10` | `REACT_PIN` | RW | per source: signal on the external error pin |
| `0x14` | `CTRL` | RW | [0] enable [1] pin invert [2] pin toggle mode [3] lock |
| `0x18` | `INJECT` | WO | pulse the given fault bits for one cycle |
| `0x1c` | `PIN_DIV` | RW | half period of the healthy pin toggle |
| `0x20` | `RAW` | RO | fault inputs before the sticky stage |
| `0x24` | `SELFTEST` | WO | [0] lockstep mismatch [1] single bit ECC error [2] double bit ECC error [3] ECC target: 0 = D-TCM, 1 = I-TCM |
| `0x28` | `CFG_SRC` | RO | which register group raised the configuration parity fault (STATUS bit 13): [0] safety controller [1] watchdog [2] clock monitor [3] interrupt controller [4] timer [5] AMS [6] core `mtvec`. Sticky; cleared by the W1C of STATUS bit 13 |

**STATUS bit 13 (configuration parity) is special: it latches and
reacts unconditionally.** Every configuration register group in the
subsystem carries one parity bit, captured at write time and compared
continuously; a mismatch sets bit 13 regardless of `ENABLE` and
`CTRL.enable`, raises the safety interrupt regardless of `REACT_IRQ`,
and asserts the error pin regardless of `REACT_PIN`. A fault that may
have corrupted the reaction configuration is not left asking that same
configuration for permission to report (findings V29/V30, fix V37).
`REACT_RST` applies normally: whether a configuration upset warrants a
reset is policy, and stays configurable.

Writing `SELFTEST[1]` or `[2]` *arms* the corruption; the selected TCM
applies it to its next write and disarms itself. It cannot work any
other way: the write to this register is an APB access and the store it
is meant to corrupt is necessarily several cycles later, so a
same-cycle scheme could never be triggered from software at all. See
finding V4-F1 in `verification_findings.md`.

Fault bit assignment (`STATUS`, `ENABLE`, `REACT_*`, `RAW`):

| Bit | Source |
|-----|--------|
| 0 | lockstep comparator mismatch |
| 1 | I-TCM corrected single bit error |
| 2 | I-TCM uncorrectable error |
| 3 | D-TCM corrected single bit error |
| 4 | D-TCM uncorrectable error |
| 5 | register file parity error |
| 6 | watchdog time-out or bad service |
| 7 | clock monitor out of range |
| 8 | bus error (unmapped access or slave error) |
| 9 | memory BIST failure |
| 10 | AMS interface (range, time-out, analog flag) |
| 11 | software signalled fault (`msafectrl[1]`) |
| 12 | unexpected core exception (illegal instruction) |
| 13 | configuration register parity error (ungated -- see above) |
| 14 | E2E bus protection: payload or address mismatch on a TCM link (took the former spare bit, so no existing bit moved) |
| 15 | fault injection self test |
| 16..31 | `fault_ext_i[15:0]` from the SoC |

## 4. Watchdog (slot 1)

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `CTRL` | RW | [0] enable [1] window mode [2] lock [3] reset request enable |
| `0x04` | `PERIOD` | RW | reload value of the down counter |
| `0x08` | `WINDOW` | RW | service accepted only below this count |
| `0x0c` | `SERVICE` | WO | write `0xa5a5_5a5a`, then `0x5a5a_a5a5` |
| `0x10` | `STATUS` | RW1C | [0] time-out [1] bad service [2] locked [3] key armed |
| `0x14` | `COUNT` | RO | current counter value |

## 5. Machine timer (slot 2)

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `MTIME_LO` | RW | free running counter, low word |
| `0x04` | `MTIME_HI` | RW | free running counter, high word |
| `0x08` | `MTIMECMP_LO` | RW | compare value, low word |
| `0x0c` | `MTIMECMP_HI` | RW | compare value, high word |
| `0x10` | `CTRL` | RW | [0] counter enable |
| `0x14` | `PRESCALER` | RW | tick every `PRESCALER + 1` clocks |

## 6. Clock monitor (slot 3)

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `CTRL` | RW | [0] enable |
| `0x04` | `MIN` | RW | lower bound in reference clock cycles |
| `0x08` | `MAX` | RW | upper bound in reference clock cycles |
| `0x0c` | `STATUS` | RW1C | [0] out of range, sticky |
| `0x10` | `COUNT` | RO | last measured value |

`MIN` and `MAX` are quasi-static: write them while `CTRL.enable` is 0.
With the default `HbDiv` of 256, the expected measurement is
`256 * f_ref / f_sys` reference cycles.

The reference domain captures the window at the boundary that starts
each measurement period, so a new window takes effect from the next
period and a write landing part way through one cannot be half applied
to it. Software does **not** have to hold the monitor disabled for any
particular length of time; the quasi-static rule remains a
recommendation, since a write racing the capture can still garble the
window for a single period.

`STATUS[0]` is set on the *edge* of a new fault, not by its level, so a
single write-one-to-clear works even while the fault level is still
propagating back from the reference domain. It did not always: see
finding V11-F1.

The first heartbeat edge after `CTRL.enable` rises ends a period that
began before the monitor was watching. It is used only to start the
first real measurement and is never compared against the window, so
enabling the monitor cannot by itself raise a fault (finding V11-F2).

A clock that is too *slow* is reported through the saturation path
rather than the range comparison: the counter stops and the fault is
raised the moment it reaches `MAX`. `COUNT` therefore reads `MAX` after
such a fault, not the true, larger measurement.

## 7. AMS interface (slot 4)

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `CTRL` | RW | [0] sequencer enable [1] continuous [2] analog test enable [7:4] test mux select [8] interrupt enable |
| `0x04` | `PERIOD` | RW | cycles between two sequencer starts |
| `0x08` | `CHMASK` | RW | channels to convert |
| `0x0c` | `STATUS` | RW1C | [0] busy [1] done [2] time-out [23:8] out of range per channel [27:24] analog flag level |
| `0x10 + 4n` | `RESULT n` | RO | last result of channel n |
| `0x30 + 4n` | `LIMIT n` | RW | [15:0] low limit, [31:16] high limit |
| `0x50` | `DAC` | RW | trim/DAC value, a write strobes `dac_we_o` |
| `0x54` | `FLAGCFG` | RW | [3:0] analog flags that raise a fault |
| `0x58` | `TIMEOUT` | RW | conversion time-out in cycles |

## 8. Memory BIST (slot 5)

Two controllers share the slot: the I-TCM one at `+0x00`, the D-TCM one
at `+0x40`.

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `+0x00` | `CTRL` | WO | [0] start [1] abort |
| `+0x04` | `STATUS` | RO | [0] busy [1] done [2] fail [6:4] march element |
| `+0x08` | `FAILADR` | RO | first failing address |
| `+0x0c` | `FAILDAT` | RO | data read at the first failing address, bits 31:0 |
| `+0x10` | `FAILDATH` | RO | the same word's seven ECC check bits, `[38:32]` |

Running the BIST destroys the memory contents and blocks the memory
under test; the core stalls while its instruction memory is being
tested.

Unlike the other slots, **an unmapped offset in slot 5 raises a slave
error rather than reading as zero.** Each controller claims its own
thirty-two bytes (`paddr[7:5]` against its base) — so `0x00..0x1f` and
`0x40..0x5f` — and the subsystem reports a bus error for anything in
the slot that neither claims.

The check bits are readable because a failure in the check-bit half of
the array is otherwise undiagnosable: it is the part only the raw test
port can reach, so `FAILDAT` alone would leave it invisible. See
finding V0-F1.

Offsets `0x01`, `0x02` and so on do not exist as far as any peripheral
is concerned: the APB bridge drives `paddr[1:0]` as zero for every
access, so a byte or halfword access is presented to the slave as a
read or write of the containing word.

## 9. Interrupt controller (slot 6)

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x00` | `PENDING` | RW1C | sticky pending bits |
| `0x04` | `ENABLE` | RW | per source enable |
| `0x08` | `CLAIM` | RO | lowest numbered pending source, `0x1f` if none |
| `0x0c` | `MSIP` | RW | [0] software interrupt |
| `0x10` | `MODE` | RW | 0 = level, 1 = rising edge |

Source assignment: bit 0 is the safety controller interrupt, bit 1 the
AMS interface interrupt, bits 15:2 are `irq_i[13:0]` from the SoC, and
bit 16 is the **APB machine timer** (slot 2). The timer's interrupt was
re-routed here when the CLINT took ownership of MTIP; bits 0–15 keep the
meaning software already had, which is why the new source appends at the
top rather than renumbering anything.

The MSIP register at `0x0c` still exists but **no longer reaches the
core**: the machine software interrupt comes from the CLINT's `msip`
(§9a). Writing it changes a register nothing consumes.

## 9a. CLINT (`0x0200_0000`)

The architectural machine timer and software interrupt, decoding the
standard RISC-V CLINT map — which is the reason it lives on the main bus
in a 64 KB window rather than in a 256-byte APB slot (`mtime` sits at
`+0xBFF8`, unreachable through a 12-bit APB address).

| Offset | Name | Access | Description |
|--------|------|--------|-------------|
| `0x0000` | `MSIP` | RW | [0] machine software interrupt — drives MSIP directly |
| `0x4000` | `MTIMECMP` | RW | timer compare, low word |
| `0x4004` | `MTIMECMPH` | RW | timer compare, high word |
| `0x8000` | `PRESC` | RW | prescaler (non-standard extension; resets to 0 = one tick per clock) |
| `0xBFF8` | `MTIME` | RW | timer counter, low word — free-runs from reset |
| `0xBFFC` | `MTIMEH` | RW | timer counter, high word |

MTIP is level: asserted while `mtime ≥ mtimecmp`. Because `mtime`
free-runs from reset, arm the comparator **relative to a read of
`mtime`**, and write the halves high-first so the 64-bit compare value
never passes through a smaller intermediate state while the counter is
running. Any other offset in the window returns a bus error, as does any
sub-word access.

The APB timer at peripheral slot 2 keeps all its registers and its
config-parity protection; only its interrupt routing changed (source 16,
§9). Its config-parity error reports as `CFGSRC` bit 7 in the safety
controller alongside the six existing sources — none of which moved.

## 10. JTAG observation window

This one is **not on the system bus** and software cannot reach it. It is
addressed over the JTAG TAP's private debug bus (`cdriscv_32s_20_jtag_tap`
instructions `IR_DBG_ADDR` = `0x8` and `IR_DBG_DATA` = `0x9`) and read by
an external debugger. It is listed here because it is a register
interface of the part, not because firmware uses it.

All six words are **read-only**. A write is accepted by the bus and
discarded — there is no writable state behind this window at all.

| Offset | Name | Description |
|--------|------|-------------|
| `0x00` | `IDCODE` | `0x0CD1_507B` — same value the TAP's IDCODE DR returns, so a scan can confirm it is talking to the window rather than to a floating bus |
| `0x04` | `STATUS` | [0] `core_sleep` [1] `fault_any` [2] `err_pin` [3] `reset_req` [4] `retire_seen` |
| `0x08` | `FAULTINT` | internal fault vector, as the safety controller sees it (16 bits) |
| `0x0c` | `FAULTEXT` | external fault vector, `fault_ext_i` (16 bits) |
| `0x10` | `LASTPC` | PC of the last retired instruction |
| `0x14` | `LASTINSN` | its encoding — 16-bit for a compressed instruction, as `retire_instr_o` presents it |

Any other address, including anything above `0x17` and any address with
a non-zero bit above [7:0], reads `0xffff_ffff`. That is a deliberate
poison value rather than zero: every register above can legitimately read
zero, so zero cannot also mean "no such address".

`LASTPC` and `LASTINSN` are **held** from the last cycle the core
retired, not sampled live, so a scan taken after the core has stopped or
parked still reports what it last executed.

**What the window cannot do** is as much a part of its specification as
what it can. It cannot halt the core, single-step it, read memory, or
write anything. Reaching memory would make the TAP a second master on
`cdriscv_32s_20_bus`, which needs arbitration against the core and turns
the debug port into a fault-injection path that has to be accounted for
in the FMEDA and disabled in the field. That argument is not made, so
the window is read-only by construction rather than by configuration.
A standard OpenOCD RISC-V configuration will **not** attach: this is not
the RISC-V Debug specification's DM register map.
