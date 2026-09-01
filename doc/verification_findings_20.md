# cdriscv-32s-20 verification findings

What verification turned up on the blocks that are new in this variant.
Companion to [verification_findings.md](verification_findings.md), which
is variant 1's log and describes variant 1.

Each entry records what was wrong, how it was found, and what was done.
The wrong guesses are kept next to the measurements that corrected them.

---

## The benches found defects, they did not confirm designs

Five of the nine new modules had real RTL defects. Two more had defects
in the bench rather than the design, which is worth recording separately
because a bench that is wrong in the DUT's favour is the more dangerous
of the two.

| module | defect | how it was found |
|---|---|---|
| E2E | XOR address fold mapped bits *i* and *i+7* to the same check bit — **11.1 % of two-bit address faults escaped** | splitting the escape statistic by fault class; a single merged 0.245 % looked fine |
| CLINT | `wr_i` on the config-parity block **left unconnected** — every legitimate config write would have looked like a fault | Verilator `PINMISSING`. Icarus accepted it silently and the bench was not checking `cfg_err_o` |
| JTAG | TDO had **no path to the instruction register**, so the IR could never be scanned out and the mandatory Capture-IR `…01` never reached the pin | the bench's Capture-IR check |
| decompressor | **five defects** — see below | exhaustive cross-check against binutils |
| PMP | two **coverage holes in the bench** — matching regions were set to *permit*, so a match and a non-match gave the same answer | the first mutation round |
| realignment | three **bench races**, one visible only under Verilator | the dual-simulator rule |
| decoder | none. The base ISA came through untouched | field-by-field equivalence against variant 1 |

The decoder line is a result, not an absence: its reference is an
implementation that is already signed off, so "no findings" there is
evidence.

---

## 1. HINTs are the trap in a compressed decoder

Four of the decompressor's five defects were the same mistake. An
encoding that *looks* degenerate — `rd = x0`, so the instruction does
nothing — is not therefore illegal. The RVC specification assigns those
code points as **HINTs** and requires them to execute as no-ops;
trapping them breaks software that emits them legitimately.

`c.li`, `c.slli`, `c.mv`, `c.add` and `c.lui` with `rd = x0` were all
made illegal. The spec distinguishes **reserved** (an implementation may
trap) from **HINT** (it must not), and the two are one line apart in the
text.

The fifth defect was structural: the whole Zcb unary group was dispatched
on `instr[6:5]` instead of `instr[4:2]`. The consequences compounded —
four reserved encodings decoded as real instructions, `c.not` and
`c.zext.b` produced the *same* expansion, and `c.mul` was missing
entirely.

A sixth was found in the same pass: `c.srli` and `c.srai` ignored
`shamt[5]`, silently shifting by `shamt[4:0]` where RV32 reserves the
encoding — while `c.slli`, three lines away in the same file, already
handled it correctly.

## 2. binutils is a reference that has to be built correctly

Getting the *reference* right took longer than writing the decompressor,
and every wrong version of it was quietly plausible.

**The raw-binary disassembler cannot be ISA-restricted.** Given a flat
`.bin`, `objdump -m riscv:rv32` still decodes `c.ldsp`, `c.addiw` and
`c.fldsp`. Worse, RV64 forms *shadow* RV32 ones: `c.jal` shares its
opcode with `c.addiw`, so an entire RV32 instruction was invisible to the
reference and every one of its encodings looked like a DUT bug.

The fix is to assemble `.insn 2, 0x….` directives into an **ELF** built
with the right `-march`. objdump then honours the architecture
attributes, and RV64-only encodings come back undecoded — which is
exactly the answer the DUT must give.

**The reference ISA must be the variant's own.** Under plain `rv32i`,
`c.mul` does not decode (it needs M) and the Zcb unary expansions do not
either (`sext.b`, `zext.h`, `sext.h` are Zbb). Both looked like DUT bugs
until the reference was rebuilt as `rv32im_zba_zbb_zbs_zca_zcb`.

**binutils is laxer than the spec in three places**, and there the DUT is
right and the tool is wrong: RV32 reserves `shamt[5] = 1` on
`c.slli`/`c.srli`/`c.srai`, and reserves `c.addi16sp` with `nzimm = 0`;
objdump decodes all of them anyway. These are commented exceptions in
`scripts/check_decompress.py` rather than silent filters — **an exception
you cannot see is indistinguishable from a bug you are hiding.**

Final state: all 65 536 encodings accounted for, zero discrepancies.

| outcome | count |
|---|---|
| expansion matches binutils | 29 823 |
| correctly rejected — not valid Zca/Zcb | 17 791 |
| correctly rejected — `instr[1:0] = 11`, not compressed | 16 384 |
| correctly rejected — RV32-reserved | 1 537 |
| correctly rejected — `c.unimp` | 1 |

## 3. A straddling instruction spans two ECC code words

A fetch word is one SEC-DED code word, so a compressed-ISA instruction
that straddles a word boundary is covered by **two independent code words
with independent error status**. `instr_err_o` for such an instruction is
the OR of the two: either being uncorrectable makes it untrustworthy.

One limitation is recorded rather than solved. Instruction length is read
from bits [1:0] of the first halfword, which live in the same code word
as the rest of it — so an uncorrectable error there makes the *length*
untrustworthy, and the realigner may mis-split the bytes that follow. It
is contained, not fixed: the instruction is delivered with `err = 1`, the
core traps, and the trap redirect re-establishes alignment from `mepc`.
Nothing mis-split is ever executed, but the mis-split does happen.

## 4. Three bench races, and why two simulators are not redundancy

The realignment bench failed three times before the DUT was ever at
fault. All three were the bench driving inputs **at** a clock edge, where
they race the DUT's own `always_ff` sampling them:

1. the word pointer advanced at the negedge, changing `word_rdata_i`
   before the very edge that consumed it — 90 948 mismatches;
2. a one-cycle `redirect` pulse was cleared in the same timestep the flop
   sampled it, so the DUT missed redirects the model applied and the two
   diverged permanently — 8 272 mismatches;
3. reset was released at a posedge, racing the asynchronous reset.

The third is the one that matters: **Icarus passed it and Verilator
failed it.** A single simulator would have signed off a bench with a
reset race in it. Together with the CLINT's `PINMISSING` — which
Verilator reported and Icarus accepted silently — that is two of two
occasions where the second simulator was the only thing that caught a
real problem.

Because `$random` differs between the two, they also run *different*
stimulus, so the realignment bench's two passes are 204 055 checks over
two independent streams rather than the same one twice.

## 5. Equivalence against a signed-off implementation

The decoder and CSR benches are the strongest evidence in this repository
because their reference is not a model written alongside the DUT — it is
variant 1, frozen in [../verif/ref/](../verif/ref/).

For the decoder the property is stated so that the extension *cannot*
silently perturb the base ISA: where variant 1 says legal, variant 2 must
produce an identical control word across all 24 fields. Five of the ten
mutants were deliberate perturbations of the base ISA — the S-immediate
LSB, the load sign-extension, BGE→BGEU, the CSR immediate form, SUB→ADD —
and all five were caught by that property alone.

For the CSR file the same idea on a stateful module: both files driven in
lockstep, every output compared every cycle, so a divergence in a
register read much later still shows up. Phase A **constrains the
stimulus** — no PMP addresses, word-aligned trap PCs, `mepc` writes with
bit 1 clear — rather than whitelisting the differences, which keeps it a
strict equality check. The three intended differences are tested on their
own in phase B.

The subtlety worth repeating from the PMP CSRs: **locking a TOR region
must also lock `pmpaddr[i-1]`**, because that address is the region's
lower bound. Locking only the cfg byte leaves the region locked while its
base can still be moved. Two mutants targeted exactly that.

## 6. misa advertised an extension the fetch path cannot deliver

The Spike co-simulation caught this on its **first run**, at retired
instruction 197 of the directed ISA program:

```
  pc=80000238  30102ef3   spike x29=40001102   rtl x29=40001106
```

`30102ef3` is `csrrs x29, misa, x0`. Bit 2 is the **C** flag, and the RTL
was setting it. The decompressor and the realigner are written and
verified, but nothing instantiates them — the fetch stage still reads
whole words — so the core was telling software it may emit compressed
instructions that the fetch path cannot deliver. Software that believed
`misa` would have executed one and taken an illegal-instruction trap at
best.

The fix is one bit, but the rule behind it is the point: **`misa` reports
what is implemented, not what is written.** Bit 2 gets set in the same
commit that puts `cdriscv_32s_20_if_align` into the fetch path, and the
CSR bench now asserts it stays clear until then, so the guard fails if
anyone sets it early.

Worth noting how it was missed: the block benches could not have caught
it. The CSR equivalence bench *checked* `misa`, but it checked it against
the value I had written down, so it agreed with the mistake. Only a
reference that knows what the ISA string means — Spike, told
`rv32im_zba_zbb_zbs_zicsr_zifencei` — disagreed. **A bench that encodes
your own assumption cannot audit that assumption.**

## 7. The architectural suite: the reference was the broken half

All 32 B tests failed on the first RISCOF run, with **byte-identical
signature hashes across `andn`, `bclr`, `bext`, `bset` and the rest.**
Distinct tests cannot agree unless one side is degenerate, and that is
what pointed at the reference rather than the DUT: Spike's signature was
all `deadbeef` — the untouched fill — while the DUT's held real values.

The cause is in RISCOF's stock Spike plugin. `build()` assembles the
`--isa` string by testing for the single letters `I M C F D` and nothing
else, so a core whose extras are all Z extensions is handed
`--isa=rv32im` and the *model* traps on every instruction under test.
Nothing errors: Spike exits normally and RISCOF blames the DUT. Fixed by
taking the Z extensions from the validated ISA string, and logging the
resulting `--isa` so it is visible in the run. Written up in
[../verif/riscof/upstream-issues.md](../verif/riscof/upstream-issues.md).

Result after the fix: **114 of 114 selected tests pass, 29 of them B.**

Two things worth carrying forward from this one:

- **Identical failure signatures across different tests are a
  single-root-cause signal**, not N findings. The same reasoning that
  turns 149 region-0 devices into one `DEGENERATE-OP` applies here.
- **I then made the mirror mistake myself.** Checking whether any
  signature was degenerate, I sampled the reference files *while RISCOF
  was still writing them* — their mtimes were inside the second I ran
  the check — and concluded 35 of the 114 passes were empty comparisons.
  They were not: re-checked after the run settled, all 114 carry real
  signatures. Reading a file that is still being written gives an answer
  that looks like a finding.

## 8. PMP: proving it fires, not just that it does not

The inherited regression passing after PMP was wired in proves only that
it **does not fire** — every region resets to OFF, so `allow_o` is 1 and
behaviour is identical to the base subsystem. That is evidence of no
regression and no evidence at all that the mechanism works.

`make pmp` is the other half, and it deliberately checks both
directions. In machine mode a PMP entry is ignored unless its **lock**
bit is set, so:

* an entry programmed with no permissions but **unlocked** must still
  permit the access;
* only a **locked** entry with no permission may deny it.

A checker that simply denied everything would sail through a one-sided
test. Three mutants confirm the test can fail: removing the gating,
removing the M-mode-unlocked bypass in the checker, and swapping the
load and store fault causes — 3 of 3 killed.

Where the exception is raised matters as much as whether it is raised.
It goes in the same pre-issue block as a misaligned address, not beside
`lsu_err`, because `start_lsu` is gated on `!take_exc`: a denied access
is never put on the bus and then retracted.

**One consequence to be aware of:** a PMP denial reports through the
safety controller's *bus-error* event, since it raises the same
`EXC_LOAD_FAULT` / `EXC_STORE_FAULT` causes. A software access violation
therefore sets the same sticky status bit as a genuine memory fault.
That is a mapping decision, not an oversight, but distinguishing the two
would need its own event source.

## 9. Turning on C broke four things, and only one was the RTL

Wiring `if_align` into the fetch path and letting the toolchain emit
compressed instructions surfaced four failures. Three were in the tests
and one was a trace artefact — the fetch path itself was right.

**The trace, not the core.** The first co-simulation mismatched on every
instruction: Spike reported `00004101` (`c.li x2,0`), the RTL reported
`00000113` (`addi x2,x0,0`). PC and register writes agreed exactly. The
retire trace was reporting the decompressor's *expansion* rather than
what was fetched. A trace that rewrites `c.li` as `addi` disagrees with
every reference model and misdescribes what is in memory, so it now
reports the fetched encoding.

**`misa` again, and this time the reference was wrong.** With C
implemented the RTL sets bit 2; Spike told `zca_zcb` does not. For RV32
without F or D the C extension *is* Zca, so the core is right and the
ISA string was under-specified. Both now use
`rv32imc_zba_zbb_zbs_zicsr_zifencei_zcb`.

**Every `mtvec` target must be explicitly 4-byte aligned.** `trap_test`
hung: the trace ran `0x5c → 0x25c → back to 0`. `trap_handler` had
landed at `0x25e` because the assembler no longer places labels on word
boundaries once it can compress, and `mtvec`'s BASE field is bits
[31:2] — so writing `0x25e` stores `0x25c`, and the core vectored two
bytes early into the middle of an instruction. `mtvec` was still 0 at
that point in the preamble, so the fault vectored to 0 and the program
restarted for ever. Every handler now carries `.align 2`.

**Patching by the word stops being safe.** The FENCE.I test overwrites
one 32-bit word at `patch_target`, which meant "replace exactly the
first instruction" only while that instruction was 32 bits. Compressed,
`li a1,1` and `ret` both fit in that word, so the patch ate the return.
The label is now pinned with `.option norvc`.

**And one thing that is genuinely gone:** instruction-address-misaligned
is unreachable with C. JALR clears bit 0 in hardware and JAL and branch
immediates are always even, so no control transfer this core can execute
raises cause 0. `trap_test`'s check for it is inverted: jump to a
deliberately halfword-aligned target and require that it runs and does
*not* trap. Asserting the absence of an exception is the only honest
form of that test once the exception cannot occur.

## 10. A 10⁹ campaign that does not close O2

The marathon reached its target: **1 015 491 890 instructions over
27 000 programs in 54 batches, every batch 500/500, zero mismatches.**
The per-batch counts sum exactly to the cumulative, so the log is
internally consistent.

It still does not close O2, and the reason is worth stating because it
is easy to miss when a number that large lands.

Batch 0 ran at 14:53. Zca/Zcb went into the fetch path at 18:31 and the
single-cycle multiplier at 19:38; the co-simulation runner was rebuilt
at 19:35. So roughly the first twenty batches exercised the
bitmanip-only core and the remainder exercised the compressed one. The
total is an accumulation across two designs, and **no single design was
run for 10⁹ instructions.**

An objective is a statement about a design, not about a tool's uptime.
Variant 1's O2 was a clean campaign against frozen RTL and this had to
match it, so the campaign was restarted from zero against a runner
rebuilt from the current RTL.

**The re-run met it**: 1 015 480 871 instructions, 27 000 programs, 54
batches, every batch 500/500, zero mismatches — runner built 00:17,
batch 0 at 00:24, last batch 06:32, and no commit touched `rtl/` or
`verif/core/` in between. Six hours of machine time to convert a number
that looked like evidence into one that is.

The general form is worth keeping: **a long-running campaign is only
evidence for the revision it ran against.** If the design changes under
it, the counter keeps going up and the evidence does not. Check the
first batch timestamp against the RTL history before quoting any
accumulated total — the previous log is kept as
`build/o2_marathon_prev_rtl.log` rather than deleted, because what it
covers is real, it just is not this design.

## 11. Two lint findings fixed rather than waived

- The PMP TOR lower bound for region 0 is a constant zero, so
  `req_addr >= 0` is always true and Verilator flagged the comparison as
  constant. The original code carried a comment saying this was intended.
  It is now **structural** — region 0 has no lower-bound comparison at
  all — so the intent lives in the RTL rather than in a comment beside a
  warning.
- The CSR file's `pmpcfg_next()` deliberately discards bits [6:5] of the
  requested byte, because they are WARL reserved and must read as zero.
  That is now stated explicitly.

A third was inherited and **wrong**: variant 1's waiver file claimed
`mepc` is word aligned because IALIGN is 32, and cited a planning
document that no longer exists. In this variant IALIGN is 16 and bit 1 is
significant. The waiver was replaced, not carried forward.

## 12. The guard that was left pointing the wrong way

§6 ends with a rule and a guard: `misa` reports what is implemented, and
the CSR equivalence bench "asserts it stays clear until then, so the
guard fails if anyone sets it early."

The guard worked. What was never done is turn it round.

Commit `4415f3b`, *"zca/zcb: into the fetch path, and misa reports C"*,
set bit 2 in `cdriscv_32s_20_csr.sv` and did not touch
`verif/block/csr/tb_csr_equiv.sv`, which still read:

```systemverilog
expect_eq(b_rdata, {2'b01, 4'b0, 26'h000_1102}, "misa (I+M+B, not C)");
if (b_rdata[2] !== 1'b0) begin
  $display("[FAIL] misa advertises C while if_align is not instantiated");
```

So from that commit onwards `make block` **failed**, on exactly the
check that had been written to protect the rule — 2 mismatches out of
400 018, phase A clean and phase B red. It was found while re-running the
full regression before an unrelated change, not by anyone running it
after the commit that broke it.

Two things are worth separating here, because they have different fixes.

**The bench was right and the design was right.** Nothing shipped wrong.
C genuinely is implemented, `misa` genuinely should report it, and the
bench genuinely should have been updated in the same commit. The check
now reads the other way — it fails if C is *absent* — because
advertising less than is implemented is as wrong as advertising more,
and a guard with no direction is not a guard.

**The regression was not run.** That is the real finding. A block
regression that takes minutes had been red for several commits, and the
work that followed it — the 10⁹ instruction marathon, the hardening run —
was all done on top. None of it is invalidated: those exercise the
design, and the design was correct. But the same silence would have
covered a defect, and the marathon in §10 is a reminder of how much
machine time gets spent on top of an assumption nobody re-checked.

The rule from §10 was *a campaign is only evidence for the revision it
ran against*. This is its neighbour: **a guard is only evidence if
someone runs it.** A guard whose expectation has gone stale does not go
quiet — it goes red, which is better — but only if the harness is
actually executed.

## 13. Two of three clock domains were signed off unconstrained

LibreLane's built-in `base.sdc` constrains exactly one clock, and prints
a warning saying so:

```
[WARNING] Multi-clock files are not currently supported by the base SDC
file. Only the first clock will be constrained.
```

This design has more than one. `ref_clk_i` is the clock monitor's
independent reference — the whole point of which is that it is *not* the
system clock, because a monitor clocked by the clock it watches cannot
report that clock's failure. In the `v2first` signoff run it was
constrained as a **data input**:

```tcl
set_input_delay 8.0000 -clock [get_clocks {clk_i}] -add_delay [get_ports {ref_clk_i}]
set_driving_cell sg13g2_buf_4 ... [get_ports {ref_clk_i}]
```

The consequences are visible in the final netlist. Its 107 flip-flops are
clocked through

```
ref_clk_i -> input83 -> fanout7111 -> fanout7102 -> fanout7094 -> 107 flops
```

`fanout*` cells are the resizer's max-fanout repair, not CTS. The domain
got a **buffer chain instead of a clock tree**, and no timing check at
all — because OpenROAD was never told it was a clock.

**This did not fail. It reported nothing, which reads as a pass.** That
is the whole hazard: every gate in the signoff table was green, and one
of them was green because it was empty.

`flow/cdriscv_32s_20.sdc` now constrains all three domains — `clk_i`,
`ref_clk_i` and the new `tck_i` — and declares them mutually
asynchronous, which is what every crossing already assumes (they all go
through `cdriscv_32s_20_sync_lvl` or `cdriscv_32s_20_pulse_sync`).

**How bad was it, really?** Worth measuring rather than asserting.
Applying the new constraints to the *existing* signoff database:

| | |
|---|---|
| Registers now timed on `ref_clk_i` | **107** (was 0) |
| Worst setup slack in that domain | **+36.8 ns** against a 40 ns period |
| Worst path arrival | 3.10 ns |
| Recovery on `ref_rst_ni` | +31.2 ns |

So the circuit was never in danger at 25 MHz — the reference domain is a
handful of counters with a 3 ns critical path. The defect was in the
**evidence**, not the silicon. That distinction is worth keeping: the
fix does not rescue a broken design, it replaces an unexamined claim
with an examined one. It would not have stayed harmless at a higher
frequency, on a larger reference domain, or if someone had put logic
there believing it was being checked.

Two smaller notes for anyone maintaining the file:

* The real variable is `FALLBACK_SDC` (`FALLBACK_SDC_FILE`,
  `BASE_SDC_FILE` and `SDC_FILE` are deprecated aliases). An SDC that
  `source`s LibreLane's own `base.sdc` through `$::env(BASE_SDC_FILE)`
  gets an unset-variable error.
* The file is self-contained rather than layered on `base.sdc`. Its path
  is an internal detail of the installed LibreLane version, and a
  constraint file that changes silently when the tool is upgraded is not
  a signoff artefact.

## 14. The JTAG debug path: three findings, none of them in the TAP

The TAP itself was already block-verified (§ the `block-jtag` bench, 21
checks, 7/7 mutants). Putting it into the subsystem needed two new
blocks — a clock-domain bridge and the window it reaches — and all three
findings came from those.

**Lint found an address aliasing bug, not an unused signal.** Verilator
reported `Bits of signal are not used: 'acc_addr_i'[31:8]`. Read as a
lint nit that is a waiver; read as a design statement it says the window
decodes only the low byte, so its six registers are **mirrored across
every 256-byte page** of the debug address space. A debugger reading a
wrong address would get a plausible answer — IDCODE at 0x8000_0000 —
instead of the poison value. The decode now covers all 32 bits. The
mutation run confirms the bench sees the difference: restoring the
low-byte decode is killed.

**The bench had the same race, twice found.** `dbg_access` waited for
`dbg_busy` to fall without first waiting for it to rise, which returns
immediately — the `busy_q` non-blocking update has not landed at the
point the `wait` is evaluated. Every read then returned the *previous*
transaction's data, and the failure log is unmistakable in hindsight:
each expected value appearing one line late, IDCODE showing up as the
answer to the FAULTINT read. This is the third bench race in this
repository (§4 has the other two) and the same shape each time.

**One mutant survives, and it is reported rather than rounded away.**
9 of 10. The survivor moves the bridge's acknowledge a cycle earlier, so
it is sent in the same cycle the read data is captured rather than one
after. It survives because the acknowledge still crosses a two-stage
synchroniser, and in zero-delay RTL simulation two synchroniser stages
always outlast a same-cycle register write. The extra stage is a
**timing** margin — it earns its keep when two tck edges are shorter than
one system clock period — and functional simulation is the wrong
instrument for it. Two earlier attempts at that mutant were worse: one
was `ack_pulse <= 1'b0; if (acc_strobe) ack_pulse <= 1'b1;`, which is
*literally* `ack_pulse <= acc_strobe` under non-blocking semantics, and
counting it as a survivor would have blamed the bench for an
equivalent mutant. **A surviving mutant is a claim about the bench, so
it is worth being sure the mutant is a real difference first.**

### What the crossing is, and what it is not

The bridge is a closed-loop toggle handshake in both directions. Address
and write data are written in the tck domain *before* the request toggle
is sent and held until the acknowledge returns, so they are static for
the whole window in which the destination could sample them; the read
data is symmetric.

The consequence is that there is **no tck:clk ratio assumption**. That
matters because the usual alternative — "TCK must be slower than the
core clock" — is easy to state, easy to violate on a bench, and
impossible to check in silicon. The bench runs the identical read
sequence at three ratios (tck at 1/7, at 1/1, and at 3.3× the system
clock) and requires the same answers; the fast-tck phase is the one that
would fail on a design that quietly assumed a slow TCK.

What the TAP reaches is six read-only words. It cannot halt the core,
single-step, or read memory, because doing any of that makes it a second
master on `cdriscv_32s_20_bus` — needing arbitration against the core,
and turning the debug port into a fault-injection path the FMEDA would
have to account for and the product would have to disable in the field.
That argument is not made here, so the window is read-only **by
construction**, not by configuration.

## 15. The critical path was never where the note said it was

`variant_status.md` had carried a prediction for months: the
single-cycle multiplier puts a combinational 33×33 array on the
writeback path, `v2first` closed 40 ns with only +1.393 ns to spare, so
if the re-harden missed timing the multiplier would be the first thing
to remove.

The re-harden missed timing — **−0.719 ns at the slow corner, TNS
−8.713 ns over 46 endpoints** — and the multiplier is on **none** of
those 46 paths. Every one of them starts in `u_core_main.u_if`.

Worse for the original theory: `v2first`'s own worst path started at the
*same net*, `u_if.rd_ptr_rdata_q`, the instruction buffer's read
pointer. The fetch stage was the critical path before the multiplier
existed. Adding Zca/Zcb's realignment deepened a path that was already
the limiting one, and the +1.393 ns that looked like margin for the
multiplier was really margin on a fetch path about to get longer.

| | `v2first` | `v2full` |
|---|---|---|
| worst-path start | `u_if.rd_ptr_rdata_q` | `u_if.rd_ptr_rdata_q` |
| cells on the path | 70 | 82 |
| of which max-fanout repair buffers | 22 | 32 |
| setup slack, slow corner | +1.393 ns | −0.719 ns |

**The mechanism was plausible and the conclusion was still wrong.** A
combinational multiplier on the writeback path really is the kind of
thing that eats a nanosecond, the margin really was thin, and the two
facts sat next to each other for long enough to look like cause and
effect. Nothing had checked *which endpoints* were critical — that
takes one report and was never run. This is the same shape as the
`npn13G2v` `le`/`we` transposition in the analog tree: **a wrong
attribution does not announce itself as one, it arrives dressed as a
plausible physical effect.**

The second thing the report says is about buffering rather than logic.
32 of the 82 cells on the critical path are `sg13g2_buf_1` — the weakest
buffer in the library — inserted by max-fanout repair, several
contributing 0.45–0.59 ns apiece at 0.37–0.66 ns slew. `SYNTH_BUFFER_CELL`
is `sg13g2_buf_1` and `MAX_FANOUT_CONSTRAINT` is 10, so a high-fanout
net in the fetch stage gets a chain of minimum-strength buffers which
the resizer does not fully undo afterwards.

That is an observation, **not** a second confident diagnosis — which is
the point of this entry. Whether restyling the buffering recovers 719 ps
is an experiment. It is worth running first only because it is a
configuration change with no RTL risk, not because the reasoning behind
it is any stronger than the reasoning that produced the multiplier
theory.

### What the same run confirms

The clock constraints from §13 did what they were written to do. Every
flip-flop in the design is now on a clock tree:

| domain | flops on a CTS tree |
|---|---|
| `clk_i` | 6457 |
| `ref_clk_i` | **107** — in `v2first` these had no tree and no timing check |
| `tck_i` | **190** — new |

and **none** on a raw or fanout-repair net. That is worth stating
plainly next to a timing failure: the run failed on a real number, and
it is the first run in this repository where every sequential element
was actually being checked.

Everything else passed on the complete RTL — routing DRC 0, antenna 0,
KLayout DRC 0, GDS XOR 0, illegal overlap clear, hold clean at every
corner, and LVS **matching uniquely** across 153 626 devices and 79 499
nets. The design is physically implementable at this die size; what it
is not, yet, is timing-closed at 25 MHz across PVT.

## 16. Zcmp: what the tools settled that memory would have got wrong

The Zcmp sequencer went in against ground truth taken from the
installed tools, not from a reading of the spec, and three details were
worth pinning down before any RTL existed:

**Spike's commit log fixed the retirement contract.** One cm.push of
four registers is ONE commit line carrying the new sp and all four
stores; the register writes are printed sorted by index and the memory
beats in execution order (descending addresses, highest list member
just below the incoming sp).  That line format became the RTL trace
contract: the cosim bench accumulates a sequence's writes and prints
them the same way, and cosim.py tokenises the whole write list instead
of its old one-register-one-memory-field match.  The tokeniser needed
one regex subtlety: an `x` register token must require a preceding
space, or the `x` inside a hex value (`0x11111111`) can start a false
match when a store value happens to be all decimal digits.

**binutils is lax about reserved rlist values, again.** The push/pop
family reserves rlist 0..3; binutils 2.46 happily disassembles those
code points as `cm.push {ra}, 0`.  The DUT traps them, and
check_decompress.py carries the commented exception -- the same class
as the shamt[5] shifts and c.addi16sp nzimm=0 from §2.  cm.mvsa01 with
r1s' = r2s' is properly rejected by binutils (`.insn`), so no exception
was needed there.

**The independent reference could be generated, not restated.**
check_zcmp.py never computes an address or an adjustment of its own:
it seeds a program whose every value flows through Spike's commit log,
maintains registers and memory from that log, and interprets the
dumped RTL step table against it.  The one place the checker's own
arithmetic could have leaked in -- the mnemonic operand for the base
adjustment -- is laundered through binutils (mnemonic to encoding) and
Spike (encoding to sp delta) before anything is compared.

One deliberate asymmetry is recorded rather than hidden: the
sp-written-first mutant produces an architecturally identical clean
run (same stores, same final sp), so the co-simulation cannot kill it.
It is killed by the directed test's PMP-denied push, which finds sp
already moved at the trap (exit code 18) -- the restartability property
is only observable on the trap path, which is exactly why the directed
test exists next to the cosim.

## 17. What the coverage re-run itself found (O6/O7)

The coverage work (2026-09-01) was mostly measurement, and a routine
summary of it lives in variant_status.md §3.9. Two things it surfaced
are findings rather than numbers.

**`multdiv` carries a verified multiply datapath the subsystem cannot
select.** Line coverage flagged the MULH/MULHSU/MULHU result arm as
unreached by every test in the merged run. That is not a stimulus gap:
variant 2's core routes *every* multiply to the new single-cycle
`cdriscv_32s_20_mult` (`start_md` fires only for `!md_is_mul`), so the
iterative multiply half of `multdiv` — datapath, correction logic and
the FSM steps that serve it — is dead in this integration. The module's
`MD_MUL` arm still read as covered, which is worth dwelling on: `op_q`
*resets* to that encoding, so the idle mux evaluates the MUL arm every
cycle, and a coverage report happily counted a dead feature as alive
because its selector happened to be the reset value. Only the
MULH-group arm, whose encoding never occurs at rest, betrayed the dead
half. Recorded as waiver W5 (with a to-do) in
verif/coverage_waivers.md; the standalone `block-multdiv` bench remains
the evidence that the logic is correct, and the FMEDA should know the
area is latent-fault surface with no functional observer.

**The coverage recipe's failure guard could not see a failing test.**
Every system-test run in the `coverage:` target is joined to its `mv`
with `&&`, and the recipe's own comment says a failing simulation is
thereby excluded from the merge. It is not: `tb_cdriscv_subsys`
reports FAIL by *display* and exits through `$finish`, so its exit code
is 0 on a failed check and the `&&` only filters crashes. Coverage
measured from a failing test would have merged silently — the same
shape as the `vvp | tee` pipefail finding that opens the Makefile,
one layer up. The two runs added this round (pmp, zcmp) capture the
log and grep the verdict; retrofitting the same guard to the
pre-existing runs is left open and noted in variant_status.md §3.9.
