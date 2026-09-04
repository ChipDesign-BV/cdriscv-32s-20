# cdriscv-32s-20 architecture

> [!NOTE]
> **This document describes cdriscv-32s-20.** It began as variant 1's
> and has been revised for this variant; the evidence behind it is this
> variant's own. See [variant_status.md](variant_status.md) for what
> holds here, per module and per objective.

> **Status (2026-09-04): O1–O7 and O9 are met on this variant's runs**
> — architectural suite 143/143, 10⁹-instruction co-simulation,
> coverage closed with reviewed waivers, eight fault-injection
> campaigns and an FMEDA on assumed rates ([fmeda.md](fmeda.md)). O8
> (gate level) is open. The chip level is hardened and timing-closed
> ([chip.md](chip.md)).

## 1. Overview

`cdriscv-32s-10` is a 32-bit RISC-V core subsystem intended for the
digital control part of a safety-critical mixed-signal SoC: a sensor
front-end, a motor or power controller, a battery monitor. It is small
and deterministic rather than fast, and every structure in it was chosen
so that a fault in it is either detected or bounded.

```
                +--------------------------------------------------+
                |              cdriscv_32s_20_subsys               |
                |                                                  |
 clk, rst ----->|  +--------------------+    +------------------+  |
 ref_clk ------>|  | core (rv32imc_b)   |    | I-TCM  SEC-DED   |  |
                |  |  main + checker    |<==>| D-TCM  SEC-DED   |  |
 irq ---------->|  |  (lockstep, DCLS)  |    |  + March C- BIST |  |
                |  |  + PMP, 8 regions  |    +------------------+  |
 fault_ext ---->|  +--------------------+                          |
                |            |                                     |
                |            v           +-----------------------+ |
 err_pin <------|  +--------------------+| timer, watchdog,      | |
 reset_req <----|  | safety controller  || clock monitor,        | |
                |  +--------------------+| irq control, AMS if   | |
 adc/dac/atest<>|            |            +-----------------------+ |
 ext APB      <>|            v                                     |
                |  +--------------------+                          |
 tck/tms/tdi -->|  | JTAG TAP -> bridge |   read-only: IDCODE,     |
 tdo, tdo_oe <--|  |   -> observation   |   status, fault vectors, |
 trst_n ------->|  |      window        |   last retired PC/insn   |
                |  +--------------------+                          |
                +--------------------------------------------------+
```

## 2. Core

`cdriscv_32s_20_core` implements `rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb`,
machine mode only. It has two stages:

* **Fetch** (`cdriscv_32s_20_if_stage` → `cdriscv_32s_20_if_align`) —
  sequential prefetch with one outstanding bus transaction and a one
  entry instruction buffer. A redirect empties the buffer and marks an
  in-flight response to be dropped. The prefetcher works in whole words;
  `if_align` turns that word stream into the 16-bit fetch granularity C
  requires, handling instructions that straddle a word boundary, and
  `cdriscv_32s_20_decompress` expands a 16-bit encoding before decode.
* **Execute** — decode, register read, ALU or multiply/divide or memory
  access, and write back, all for one instruction at a time, sequenced
  by a four state FSM (`ST_RUN`, `ST_WAIT_LSU`, `ST_WAIT_MD`,
  `ST_SLEEP`).

Because exactly one instruction is in flight in the execute stage there
is no forwarding, no hazard detection and no speculative state. The
cost is throughput (a simple ALU instruction retires in one cycle when
the fetch keeps up, a load or store takes the memory latency, a multiply
or divide takes 33 cycles). The benefit is that the state space a
safety analysis has to cover stays small and every instruction has a
statically known worst case latency.

| Unit | File | Notes |
|------|------|-------|
| Fetch | `cdriscv_32s_20_if_stage.sv` | 1 outstanding, 1 buffered instruction |
| Decode | `cdriscv_32s_20_decoder.sv` | pure combinational, illegal instruction detection |
| Register file | `cdriscv_32s_20_regfile.sv` | 32x32 flops, odd parity per word |
| ALU | `cdriscv_32s_20_alu.sv` | one shared adder for arithmetic and compares |
| Multiply | `cdriscv_32s_20_mult.sv` | single cycle, 33×33 |
| Divide | `cdriscv_32s_20_multdiv.sv` | 32 iterations, data independent latency |
| Load/store | `cdriscv_32s_20_lsu.sv` | single beat, misaligned access traps |
| PMP | `cdriscv_32s_20_pmp.sv` | 8 regions, data accesses and instruction fetch (one checker instance per port) |
| Decompress | `cdriscv_32s_20_decompress.sv` | Zca/Zcb, 16 → 32 bit |
| Realign | `cdriscv_32s_20_if_align.sv` | 16-bit granularity, straddle handling |
| CSR | `cdriscv_32s_20_csr.sv` | M-mode subset, PMP registers, two safety CSRs |

Not implemented, on purpose: user mode, caches, branch prediction, and a
RISC-V Debug Module. Each would add state that is hard to argue about,
and none is needed for a small control loop. What *is* present is a
narrower thing — an IEEE 1149.1 TAP reaching six read-only words (§5a) —
chosen precisely because it adds no state the core has to reason about.

Zcmp (`cm.push`/`cm.pop`/`cm.popret`/`cm.popretz`/`cm.mva01s`/
`cm.mvsa01`) could not live in the combinational decompressor — those
encodings expand to a *variable-length sequence* of loads and stores
plus a stack adjustment, not to one 32-bit instruction — so it is the
one extension with its own sequencer in the core: the decompressor
flags the encoding (`cdriscv_32s_20_decompress.zcmp_o`), a stateless
step table (`cdriscv_32s_20_zcmp`) says what each micro-operation does,
and the core FSM's `ST_SEQ` state walks it one LSU access or one
register write at a time over the existing one-at-a-time datapath.
Each cm.* retires once, is not interruptible mid-sequence (bounded
worst case: 13 memory beats plus the sp write), and writes sp as its
last step so a faulting beat leaves the instruction restartable from
`mepc`.  See programming_manual.md §1.2.

## 3. Bus

All ports use an OBI-like protocol: `req`/`gnt` for the address phase
and `rvalid` for the response, with at most one outstanding transaction
per master, and `rvalid` never in the same cycle as `gnt`.

`cdriscv_32s_20_bus` connects two masters (instruction, data) to three slaves
(I-TCM, D-TCM, peripheral bridge) plus an internal error responder:

* the instruction master reaches the I-TCM only; any other address it
  produces returns an error, which turns a runaway program counter into
  a reported fault instead of a silent wrap around,
* the data master reaches everything and wins the I-TCM arbitration, so
  it can never be starved by the fetcher,
* unmapped addresses return an error response rather than hanging.

## 4. Memories

`cdriscv_32s_20_tcm` stores 39 bits per word: 32 data bits and 7 check bits of
a Hsiao SEC-DED code (`cdriscv_32s_20_ecc_secded.sv`, generated by
`scripts/gen_secded.py`). Reads correct single bit errors and report
double bit errors as a bus error. Sub-word writes become a two cycle
read-modify-write because the check bits cover the whole word.

Each TCM has a raw 39-bit test port for the March C- BIST controller
(`cdriscv_32s_20_mbist.sv`) and a fault injection input that lets software
corrupt a code word on purpose to prove the detection path works.

## 5. Safety architecture

| Mechanism | Block | Detects |
|-----------|-------|---------|
| Dual core lockstep, delayed by `LockstepDly` cycles | `cdriscv_32s_20_lockstep` | faults in core logic |
| SEC-DED on both TCMs | `cdriscv_32s_20_tcm` | memory bit flips |
| Odd parity on the register file | `cdriscv_32s_20_regfile` | register file bit flips |
| March C- BIST | `cdriscv_32s_20_mbist` | memory manufacturing and latent faults |
| Windowed watchdog | `cdriscv_32s_20_wdog` | program flow failure |
| Clock monitor against a reference clock | `cdriscv_32s_20_clkmon` | clock loss, frequency drift |
| Bus error responder | `cdriscv_32s_20_bus` | access to unmapped addresses |
| Range check on ADC results, analog flags | `cdriscv_32s_20_ams_if` | analog domain failure |
| Configuration register parity | `cdriscv_32s_20_cfg_parity`, one per register group | an upset silently disarming or re-tuning any mechanism above |
| Fault collection and reaction | `cdriscv_32s_20_safety_ctrl` | reports and reacts |

Every mechanism ends in `cdriscv_32s_20_safety_ctrl`, which holds one sticky
status bit per source and a configurable reaction (interrupt, reset
request, external error pin). The configuration can be locked until the
next reset.

One status bit is different by design. Configuration parity errors
latch STATUS bit 13 **ungated** — not maskable by `ENABLE` or
`CTRL.enable`, with the interrupt and error pin reaction hardwired
rather than taken from `REACT_*` — because the register a fault
disabled may be the one that would have recorded it (findings V29/V37;
measured effect: latent configuration upsets 46.4 % → 0). `CFG_SRC`
(0x28) names the register group that raised it.

The 64-bit `mcycle`/`minstret` counters are implemented as four 16-bit
segments with carries predicted one cycle early into flip-flops
(`cdriscv_32s_20_counter64`) — architecturally identical to a flat 64-bit
increment (proven by sequential equivalence), at a quarter of the carry
depth, after V38 measured the flat increment as the subsystem's
critical path.

The external error pin has two modes. In level mode it is asserted when
a fault is latched. In toggle mode it carries a square wave while the
subsystem is healthy and stops on a fault, so an external monitor also
notices a subsystem that has stopped working entirely, and a stuck-at
fault on the pin itself no longer looks healthy.

## 5a. Debug

An IEEE 1149.1 TAP (`cdriscv_32s_20_jtag_tap`), written in-house rather
than taken from pulp-platform/riscv-dbg: a third-party debug stack would
have to be qualified alongside the core, and for a safety part the
cheaper argument is a small TAP with a deliberately narrow surface.

Three blocks, two clock domains:

| Block | Domain | Role |
|---|---|---|
| `cdriscv_32s_20_jtag_tap` | `tck_i` | the 16-state controller, IR/DR scans, BYPASS and IDCODE, plus two private instructions reaching a debug bus |
| `cdriscv_32s_20_dbg_bridge` | both | closed-loop toggle handshake in each direction |
| `cdriscv_32s_20_dbg_win` | `clk_i` | six read-only words |

The bridge holds address and write data static in the `tck` domain from
before the request toggle is sent until the acknowledge returns, and the
read data symmetrically. Two consequences follow. There is **no
tck:clk ratio assumption** — the conventional "TCK must be slower than
the core clock" rule is easy to state, easy to violate on a bench, and
impossible to check in silicon. And a request arriving while one is
outstanding is *dropped* rather than overwritten: a dropped request
stalls the debugger, an overwritten one has it reading somebody else's
address.

The window exposes IDCODE, a status word, the two fault vectors, and the
PC and encoding of the last retired instruction. It is read-only **by
construction** — there is no writable state behind it — and it cannot
halt the core, single-step it, or read memory. Doing any of that would
make the TAP a second master on `cdriscv_32s_20_bus`, requiring
arbitration against the core and turning the debug port into a
fault-injection path that the FMEDA would have to account for and the
product would have to disable in the field. That argument is not made,
so the boundary is drawn where it can be defended.

A standard OpenOCD RISC-V configuration will **not** attach: this is not
the RISC-V Debug specification's DM register map. That is the trade —
no third-party code to qualify, at the cost of a custom adapter script.

## 6. Clocking and reset

Three clock domains:

* `clk_i`, the system clock;
* `ref_clk_i`, used by the clock monitor — deliberately independent,
  because a monitor clocked by the clock it watches cannot report that
  clock's failure;
* `tck_i`, the JTAG TAP.

Every crossing is a single bit through the synchronisers in
`cdriscv_32s_20_sync.sv`, plus two multi-bit transfers that are qualified
by a handshake rather than synchronised bit by bit: the clock monitor's
measurement result, captured after the toggle that announces it, and the
JTAG debug bus, which holds address and data static across a closed-loop
toggle handshake in both directions (§5a).

All three must be constrained and declared mutually asynchronous. In the
first hardening run they were not, and `ref_clk_i` was signed off as a
data input — see §13 of
[verification_findings_20.md](verification_findings_20.md).

The external reset is synchronised once (`cdriscv_32s_20_rst_sync`) and drives
everything. A reset request from the watchdog or the safety controller
generates a warm reset that restarts the core but leaves the peripherals
and their status registers standing, so software can find out afterwards
why it restarted.

## 7. Parameters of `cdriscv_32s_20_subsys`

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `Lockstep` | 1 | instantiate the checker core |
| `LockstepDly` | 2 | delay between main and checker core |
| `RV32M` | 1 | multiply/divide extension |
| `RfParity` | 1 | register file parity |
| `ItcmWords` / `DtcmWords` | 4096 | memory size in 32-bit words |
| `MbistAuto` | 0 | run the memory BIST after reset (destructive) |
| `ItcmBase` / `DtcmBase` / `PeriphBase` | 0x0, 0x1000_0000, 0x2000_0000 | address map |
| `HartId` | 0 | value of `mhartid` |
| `WarmRstLen` | 16 | length of the warm reset in cycles |
