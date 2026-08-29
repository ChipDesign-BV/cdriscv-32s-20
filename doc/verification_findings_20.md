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

## 9. Two lint findings fixed rather than waived

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
