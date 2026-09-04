# cdriscv-32s-20 programming manual

> [!NOTE]
> **This document describes cdriscv-32s-20.** It began as variant 1's and
> has been revised for this variant — the port list, the clock domains,
> the register map and the assumptions of use are this design's. The evidence
> behind it is this variant's own — O1–O7 and O9 are met on this
> repository's runs, O8 (gate level) is open — and any measured figure
> still quoted from variant 1 is labelled as such where it appears. See
> [variant_status.md](variant_status.md) for what holds here.

The firmware developer's view: what the machine looks like from
software, how to trap, how to drive each peripheral, and what the
safety mechanisms require *you* to do.

Companion documents, referenced rather than repeated:
[register_map.md](register_map.md) is the bit-level reference for every
register named here; [integration.md](integration.md) is the SoC
integrator's manual; [safety_manual.md](safety_manual.md) carries the
safety argument. Where this manual gives a register offset it is for
orientation — the authoritative bit definitions are in the register
map.

**Status.** Verified to objectives O1–O9 of
[verification_plan.md](verification_plan.md); may be used in a project.
**Not qualified for safety-critical use.** No compliance with any
functional safety standard is claimed.

## 1. The machine

| Property | Value |
|----------|-------|
| ISA | `rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb_zcmp` |
| Privilege | **machine mode only** — no U or S mode, no virtual memory |
| Memory protection | **PMP, 8 regions**, gating data accesses and instruction fetch (§6a) |
| Registers | 32 × 32-bit, `x0` hardwired zero, odd parity per word |
| Endianness | little |
| Misaligned data access | **traps** — no hardware fixup (§4.2) |
| Compressed (C) | **implemented** — Zca and Zcb; IALIGN is 16 |
| Bit manipulation | **Zba, Zbb, Zbs** |
| Zcmp (`cm.push`/`cm.pop`/`cm.popret`/`cm.popretz`/`cm.mv*`) | **implemented** — sequenced in the core, one retirement per instruction (§1.2) |
| Atomics (A), float (F/D) | not implemented |

`misa` reports I, M, B and C, and reports them because they are
implemented (Zcmp has no `misa` bit of its own — the RISC-V spec
assigns it none, so implementing it changes the ISA string and not the
CSR) — see §6 of
[verification_findings_20.md](verification_findings_20.md) for what
happened the one time it did not.

Because there is no U mode, there is no privilege boundary inside the
subsystem: all code runs in machine mode. PMP bounds an *erroneous*
access, not a hostile one — in machine mode an entry is ignored unless
its lock bit is set, so software that has not locked a region can simply
rewrite it. Isolation against malicious code is a software-architecture
problem, not something this hardware will enforce.

### 1.1 Toolchain

```sh
riscv32-unknown-elf-gcc -march=rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb_zcmp \
    -mabi=ilp32 -nostdlib -nostartfiles -T link.ld -o app.elf app.c start.S
```

`-mno-relax` was required in variant 1 because that core trapped on any
16-bit encoding (finding V36). This variant implements C, so relaxation
is safe and the flag is no longer needed.

### 1.2 Zcmp sequences: atomicity, latency, restartability

`cm.push` / `cm.pop` / `cm.popret` / `cm.popretz` / `cm.mva01s` /
`cm.mvsa01` execute as an internal sequence of loads or stores plus a
stack-pointer adjustment, but architecturally each is ONE instruction:
one retirement, `minstret` increments once, and the trace/lockstep
interface reports the 16-bit encoding at its own PC.

Three consequences matter to software:

* **Interrupt latency (WCET).** A sequence is not interruptible once
  started; a pending interrupt is taken immediately before the
  instruction or after it completes.  The worst case is
  `cm.push {ra, s0-s11}`: 13 memory beats plus the sp write, about
  28 cycles on zero-wait-state TCMs, plus any bus wait states.  Add
  that bound to the interrupt-latency budget of any loop that uses the
  full register list.
* **Mid-sequence exceptions are restartable.** If a memory beat faults
  (PMP denial, bus error, misaligned sp), the trap reports
  `mepc` = the cm instruction's PC and `mtval` = the offending
  address, and **sp has not moved** — the sp write is always the
  sequence's final step.  An `mret` back to `mepc` therefore re-runs
  the whole instruction correctly: its source values (sp and, for a
  push, the saved registers) are intact.  Memory below the final sp
  may have been written by the completed beats of a faulted `cm.push`;
  the Zc specification declares that region volatile across the
  instruction, so no software-visible state is lost.
* **A denied beat never reaches the bus.**  The PMP check runs before
  each beat is issued, exactly as it does for ordinary loads and
  stores.

Two things the assembler will now do that it did not before, both of
which bit this repository's own tests (§9 of
[verification_findings_20.md](verification_findings_20.md)):

* **Labels are no longer word aligned.** `mtvec`'s BASE field is bits
  [31:2], so writing a handler address of `0x25e` stores `0x25c` and
  vectors two bytes early, into the middle of an instruction. Put
  `.align 2` before every `mtvec` target.
* **Patching by the word stops being safe.** Overwriting one 32-bit word
  no longer means "replace exactly one instruction" — two compressed
  instructions fit there. Pin any self-modifying target with
  `.option norvc`.

Memory image: `scripts/mkimage.py` turns a binary into the 39-bit
ECC-encoded words the TCMs expect. Loading a raw binary directly into
the arrays produces uncorrectable ECC errors on the first fetch.

### 1.2 Memory map

| Range | Contents |
|-------|----------|
| `0x0000_0000` | I-TCM — instruction fetch **and** data reads |
| `0x1000_0000` | D-TCM |
| `0x2000_0000` | peripherals, sixteen 256-byte slots (§5) |
| anything else | bus error → load/store access fault |

Both TCMs are SEC-DED protected: single-bit errors are corrected
transparently and reported; double-bit errors raise an access fault at
the instruction that touched them. The path *to* the TCMs — address
decode, bus muxing, the interconnect — is separately covered by
end-to-end protection: check bits over `{payload, address}` travel with
every TCM access, so a corrupted transfer or a wrong-address delivery
sets `STATUS` bit 14 in the safety controller. The access itself still
completes (a corrupted write is detected, not blocked), so treat bit 14
as it deserves: data reached the wrong place, and the reaction should
usually be a reset.

## 2. Performance model

Straight-line integer code retires **one instruction per cycle**. The
costs that matter for a worst-case execution time budget:

| Operation | Cost |
|-----------|------|
| ALU, load, store (aligned, hit) | 1 cycle |
| Taken branch / jump | + pipeline refill |
| `mul`, `mulh[su|u]` | 1 cycle — single-cycle 33×33 multiplier |
| `div`, `rem` | **33 cycles**, constant — no early exit |
| Partial-word store (`sb`, `sh`) | 2 cycles — read-modify-write for the ECC code word |
| CSR access | 1 cycle |

Two consequences worth designing around: the divider is constant-time
(the divider block serves *only* divides since 2026-09-02 — every
multiply retires in one cycle through the dedicated multiplier), so a
division's cost is predictable but never cheap, and byte or halfword
stores cost double what word stores do because the ECC check bits cover
the whole word. Prefer word-aligned structures in hot paths.

`mcycle`/`minstret` (and their read-only `cycle`/`instret` shadows) are
64-bit and free-running; read the high word, the low word, then the
high word again and retry if it changed.

## 3. Startup

The ordering constraints are in [integration.md](integration.md) §5;
`tb/sw/start.S` is a worked example. The parts that surprise people:

1. **Run the memory BIST, or write every TCM word yourself.** This is
   not only a test: the BIST writes every location, and the prefetcher
   will fetch past the end of your program. An unwritten word is an
   arbitrary code word and will most likely raise an uncorrectable ECC
   error. Set `MbistAuto` or drive slot 5 (§5.6).
2. **Zero every architectural register before enabling lockstep.** The
   two cores must start from identical state or the comparator will
   flag a mismatch that never happened. Write all 31 registers.
3. Configure the safety mechanisms, then **lock them** (§5.1, §5.2).
4. Set `mtvec`, enable only the interrupts you handle, enter the
   control loop.

## 4. Traps

### 4.1 Model

`mtvec` supports direct (bit 0 = 0, all traps to `BASE`) and vectored
(bit 0 = 1, interrupts to `BASE + 4 × cause`) mode. On a trap the core
writes `mepc`, `mcause`, `mtval`, copies `MIE` to `MPIE` and clears
`MIE`; `mret` reverses it. There is no trap nesting in hardware — if
you want it, re-enable `MIE` in the handler after saving state.

Interrupts are taken at instruction boundaries only.

### 4.2 Causes

| `mcause` | Cause | `mtval` |
|---|---|---|
| 0 | instruction address misaligned — **unreachable on this core**, see below | target address |
| 1 | instruction access fault (bus error, uncorrectable ECC on fetch, or PMP-denied execute) | PC of the instruction |
| 2 | illegal instruction | the instruction word |
| 3 | breakpoint (`ebreak`) | — |
| 4 / 6 | load / store address misaligned | the address |
| 5 / 7 | load / store access fault | the address |
| 11 | environment call (`ecall`) | — |
| 0x8000_0003 / 7 / B | software / timer / external interrupt | — |

**Misaligned data accesses trap.** There is no hardware fixup: a word
load from an address with either low bit set, or a halfword load from an
odd address, raises cause 4. If your code can generate them, either fix
the alignment or emulate in the handler.

**Cause 0 cannot occur.** With C implemented IALIGN is 16, JALR clears
bit 0 in hardware, and JAL and branch immediates are always even — so no
control transfer this core can execute is misaligned. Do not write a
handler that relies on receiving it.

**A PMP denial reports as a load or store access fault** (cause 5 / 7),
raised before the request reaches the bus. It shares those causes with a
real memory fault, and therefore also shares the safety controller's
bus-error status bit: a software access violation sets the same sticky
bit as a genuine one. Distinguishing them would need a separate event
source and is not implemented.

### 4.3 A minimal handler

```asm
    .align 6                    # mtvec needs 64-byte alignment here
trap_entry:
    csrrw  sp, mscratch, sp     # swap in the handler stack
    addi   sp, sp, -64
    sw     ra, 0(sp)
    # ... save what you clobber ...
    csrr   t0, mcause
    bltz   t0, interrupt        # high bit set => interrupt
    # exception: t0 is the cause, mepc points at the faulting insn
    csrr   t1, mepc
    addi   t1, t1, 4            # skip it, if that is your policy
    csrw   mepc, t1
1:  # ... restore ...
    csrrw  sp, mscratch, sp
    mret
```

## 5. Peripherals

Every peripheral lives in a 256-byte slot at `0x2000_0000 + slot×0x100`
and is accessed with ordinary word loads and stores. Unused slots and
unmapped offsets raise a bus error, which is deliberate: a stray
pointer into peripheral space traps rather than silently reading zero.

### 5.1 Safety controller (slot 0) — the one you must get right

Every fault in the subsystem ends here as a sticky bit in `STATUS`,
with a configurable reaction (`REACT_IRQ`, `REACT_RST`, `REACT_PIN`).
Configure it, then set `CTRL.lock` so a runaway program cannot switch
the safety reactions off. The lock survives until reset.

**`STATUS` bit 13 — configuration parity — is different, and it is the
one bit your handler must implement.** Every configuration register
group in the subsystem carries a hardware parity bit. A mismatch
latches bit 13 **ungated**: it raises the safety interrupt and asserts
the error pin regardless of `ENABLE`, `CTRL.enable` and `REACT_*`,
because those are precisely the registers a fault may have corrupted.

```c
void safety_isr(void) {
    uint32_t st = SAFETY->STATUS;
    if (st & (1u << 13)) {                 /* configuration parity */
        uint32_t src = SAFETY->CFG_SRC;    /* which group (0x28)   */
        reprogram_group(src);              /* rewrite it: this also
                                              rebaselines its parity */
        SAFETY->STATUS = (1u << 13);       /* W1C, after the rewrite */
    }
    /* ... other sources ... */
}
```

Rewriting the group *before* clearing the bit matters: clearing first
leaves the corruption in place and the bit simply sets again.

Without this mechanism, 46.4 % of configuration upsets were latent — a
safety mechanism silently disabled while the program kept producing
correct answers. With it, zero of 2 600 (findings V29/V37).

`SELFTEST` and `INJECT` let software prove the detection paths work
in-mission: force a lockstep mismatch, corrupt a TCM code word, or
pulse a fault bit. Writing `SELFTEST` *arms* a TCM corruption which the
next write to that memory applies — it cannot be same-cycle, because
the write you want to corrupt is necessarily several cycles after the
APB access that arms it.

### 5.2 Watchdog (slot 1)

Windowed: servicing too early is as much a fault as not servicing at
all. Service with the two-key sequence (`KEY_A` then `KEY_B` to
`SERVICE`); any other value, or `KEY_B` out of window, is a bad-service
fault. Configure `PERIOD` and `WINDOW`, then set `CTRL.lock`.

**Service it from exactly one place in your control loop.** Servicing
from an interrupt handler defeats the purpose — the loop can be dead
while the timer interrupt still runs.

### 5.2a CLINT (`0x0200_0000`) — the machine timer and software interrupt

MTIP and MSIP come from here. It decodes the standard RISC-V map —
`msip` at `+0x0000`, `mtimecmp` at `+0x4000/0x4004`, `mtime` at
`+0xBFF8/0xBFFC`, plus a non-standard prescaler at `+0x8000` — so code
written for any standard CLINT works unchanged.

Three rules, each of which has already cost a debug session somewhere:

* **Word accesses only.** A sub-word access returns a bus error rather
  than being silently widened — a byte write into a 64-bit counter has
  no defined meaning.
* **`mtime` free-runs from reset** (prescaler resets to 0 = one tick per
  clock), so set deadlines *relative to a read of `mtime`*, never as
  absolute small numbers.
* **Write `mtimecmp` high word first.** MTIP is level (`mtime >=
  mtimecmp`); hi-then-lo keeps the 64-bit compare value from passing
  through a smaller intermediate state while the counter runs.

### 5.3 APB timer (slot 2)

64-bit `mtime` with a prescaler, and `mtimecmp`; write the high word
first when setting a new deadline. `mtimecmp` is parity-protected
(§5.1).

This is **no longer the machine timer**: since the CLINT took MTIP, its
interrupt arrives as interrupt-controller **source 16** (§5.7) and is
taken as the *external* interrupt (`mie.MEIE`, cause `0x8000000B`),
claimed and dispatched like any other peripheral source. Its registers
and behaviour are otherwise unchanged, which is what keeps existing
register-level software working.

### 5.4 Clock monitor (slot 3)

Counts `clk_i` edges against an independent reference clock and faults
if the ratio leaves `[MIN, MAX]`. Configure the window, then enable —
enabling first can latch a spurious fault from the partial first
measurement. Choose the window from the real ratio with margin for both
oscillators' tolerance; too tight and it trips on nothing.

### 5.5 AMS interface (slot 4)

Sequences ADC conversions over the channels in `CHMASK`, compares each
result against per-channel `LIM_LO`/`LIM_HI`, and raises a range fault
outside them. One-shot or continuous (`CTRL.cont`). `STATUS` carries
done, timeout and per-channel range bits. The DAC/trim output has a
write strobe. Limits and channel mask are parity-protected.

### 5.6 Memory BIST (slot 5)

March C- over each TCM, I-TCM at `+0x00` and D-TCM at `+0x40`. Start,
poll `STATUS.done`, check `STATUS.fail`; `FAILADR`/`FAILDAT` localise a
failure. **Running it destroys memory contents** — run it before
loading anything you care about. Note the slot's two controllers each
claim 16 bytes, and offsets belonging to neither raise a bus error.

### 5.7 Interrupt controller (slot 6)

`NumSrc` SoC lines, each edge or level (`MODE`), with `ENABLE`,
sticky-for-edge `PENDING`, and a `CLAIM` register giving the
lowest-numbered active source. Level sources follow their input; edge
sources stay set until written back to `PENDING`. `ENABLE` and `MODE`
are parity-protected.

Source 16 is the APB timer (§5.3). The `MSIP` doorbell register still
exists but **no longer reaches the core** — the machine software
interrupt is the CLINT's `msip` (§5.2a). Writing the doorbell changes a
register nothing consumes; it is kept only so the register map does not
shift.

## 6. Core-local safety CSRs

| CSR | Address | Access | Contents |
|-----|---------|--------|----------|
| `msafestat` | `0x7c0` | RW1C | [0] register-file parity error, [1] illegal-instruction trap, [2] bus-error trap, [3] lockstep alert |
| `msafectrl` | `0x7c1` | RW | [0] fault output enable, [1] software fault trigger (self-clearing) |

`msafestat` accumulates core-local events even when the corresponding
trap is handled and forgotten — read it periodically if you want to
know that a register-file parity error was corrected under you.

Writing `msafectrl[1]` raises a software fault into the safety
controller. That is the intended way for software that detects a
problem of its own — a failed plausibility check, a corrupted data
structure — to enter the same reaction machinery as a hardware fault.

**One caveat with teeth**: if the fault you are reporting is that the
safety controller's own configuration is corrupt, the report may have
nowhere to go — the register the fault disabled is the one that would
record it. That is exactly why configuration parity latches ungated
(§5.1), and why an integrator is told to route the error pin outside
this subsystem's failure domain.

## 6a. Physical memory protection

Eight regions, standard `pmpcfg0..3` / `pmpaddr0..15`. Two rules govern
whether a region does anything at all, and both catch people out:

* **In machine mode an entry is ignored unless its lock bit is set.**
  Programming a region with no permissions does *not* deny an M-mode
  access; only a **locked** entry does. Since this core has no U mode,
  that means PMP here is entirely a locking mechanism.
* **Locking a TOR region also locks `pmpaddr[i-1]`**, because that
  address is the region's lower bound. Locking the config alone would
  leave the boundary movable.

A lock is permanent until reset. Data accesses **and instruction
fetch** are both checked; a denial never reaches the bus. A denied load
or store raises cause 5 or 7 (§4.2). Executing from a region a locked
entry denies X on raises cause 1, with `mtval` and `mepc` both holding
the PC of the denied instruction — but only if the instruction is
actually *executed*: the prefetcher routinely runs a few words past a
taken branch, and a denied prefetch that execution never reaches is
discarded without a trap. The unlocked-means-permitted rule above
applies to fetch exactly as to data: with no U mode, an unlocked X=0
entry denies nothing.

Two practical notes. The checker judges fetch per 32-bit word, so a
compressed-code instruction straddling a word boundary faults if
*either* word is denied. And after writing `pmpcfg`/`pmpaddr`, code
already prefetched was checked under the old configuration — issue a
`fence.i` if the new region must bind the very next instructions.

**The PMP arrays carry configuration parity** (since 2026-09-02): a
bit flip in any `pmpcfg`/`pmpaddr` storage — locked or not, exercised
or not — latches `STATUS` bit 13 within a couple of cycles, exactly as
an `mtvec` or `mtimecmp` flip does (§5). The parity re-baselines on
every architectural write to the group, so software configuring PMP
never sees a false flag; what it *should* do is treat `FLT_CFG_PAR`
after lock-down as a protection-integrity alarm, because a flipped
lock bit or boundary is precisely what the mechanism reports. Before
this the arrays were the one quasi-static configuration in the design
without a parity guard — fault injection measured 90.8 % of array
upsets as silently latent, which is why the guard exists.

`make pmp` is the directed test and exercises both directions on both
ports — programmed-but-unlocked must still permit (and still execute),
locked-without-permission must deny — because a checker that denied
everything would pass a one-sided test.

## 6b. The JTAG port is not for firmware

There is a JTAG TAP, but software cannot reach it and it cannot reach
software's memory. It exposes six read-only words to an external
debugger — IDCODE, a status word, the two fault vectors, and the PC and
encoding of the last retired instruction — and cannot halt the core,
single-step it, or write anything. See §10 of
[register_map.md](register_map.md). A standard OpenOCD RISC-V
configuration will not attach; this is not the RISC-V Debug
specification's DM.

## 7. Idioms worth knowing

**Reading a 64-bit counter safely.**

```c
static uint64_t read_mcycle(void) {
    uint32_t hi, lo, hi2;
    do { hi  = csr_read(mcycleh);
         lo  = csr_read(mcycle);
         hi2 = csr_read(mcycleh);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}
```

**Self-modifying code and loaded images.** After writing instructions
to the I-TCM — a bootloader, a patch — execute `fence.i` before jumping
to them. Without it the prefetch buffer may still hold stale words.

**Word-aligned data structures.** Byte and halfword stores cost two
cycles (§2); in a hot loop that is a doubling worth avoiding.

**Checking a configuration you did not write.** After any reset that is
not a cold reset, the safety status survives by design. Read `STATUS`
early in startup and decide deliberately whether the previous fault
matters; do not clear it reflexively.

## 8. Worked example: minimal safe main

```c
int main(void) {
    bist_run_and_check();            /* §3 step 1  */
    zero_all_registers();            /* §3 step 2, in asm before this */

    CLKMON->MIN = min_ratio;         /* §5.4: window, then enable */
    CLKMON->MAX = max_ratio;
    CLKMON->CTRL = CLKMON_ENABLE;

    SAFETY->ENABLE    = 0xffffffff;  /* §5.1: all sources count */
    SAFETY->REACT_IRQ = 0xffffffff;
    SAFETY->REACT_PIN = 0xffffffff;
    SAFETY->CTRL      = SAFETY_ENABLE | SAFETY_LOCK;

    WDOG->PERIOD = period;           /* §5.2 */
    WDOG->WINDOW = window;
    WDOG->CTRL   = WDOG_ENABLE | WDOG_WINDOW_MODE | WDOG_LOCK;

    csr_write(mtvec, (uint32_t)trap_entry);
    csr_write(mie, MIE_MEIE | MIE_MTIE);
    csr_set(mstatus, MSTATUS_MIE);

    for (;;) {
        do_control_work();
        wdog_service();              /* exactly one call site */
    }
}
```

## 9. What software cannot do

* **Reach a mechanism that is off.** Locked configuration stays locked
  until reset — by design; that is what stops a runaway program
  disarming the safety case.
* **Test everything from software.** Some paths are unreachable from
  software by construction: a reset-request reaction resets the core
  that would observe it. Those are covered by the bench
  (`verif/safety/tb_safety.sv`), not by firmware.
* **Rely on a mechanism it never checks.** A read-back check covers
  exactly what it reads back — one register left out of a scrub loop
  stayed 100 % latent across a whole campaign (finding V30).
